// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Drives the production Shaar panel models against the pinned engine and a
/// loopback page. Every window remains hidden throughout the run.
@MainActor final class DevToolsPanelsProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private let results = DevToolsPanelResults()

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    let originalSpace = store.session.selectedSpaceID
    guard
      store.createSpace(
        name: "DevTools Panels", sharingProfile: store.session.selectedSpace.profileID,
        tint: .ocean)
    else { throw Failure("Could not create isolated DevTools Space") }
    let space = store.session.selectedSpaceID
    defer {
      store.perform(.space(originalSpace))
      _ = store.removeSpace(space)
    }
    let page = url("/inspector-tools")
    store.perform(.open(page))
    guard let tab = store.session.selectedPage?.tab.id else {
      throw Failure("No DevTools fixture tab")
    }
    try await wait("fixture page ready") {
      self.engine.liveTabs.contains(tab) && self.engine.pages[tab]?.loading == false
        && self.engine.runtime.view(forTabID: tab.uuidString)?.superview != nil
    }
    guard let target = engine.siteControlTarget, target.tabID == tab,
      engine.showDeveloperTools(for: target),
      let shell = engine.shaarDevTools[tab], let inspector = engine.inspectors[tab]
    else { throw Failure("Shaar panel shell did not open for the selected tab") }
    try await wait("live panel lease") { shell.streamAvailable }

    await check("console-network") {
      _ = try await inspector.evaluate(
        "console.error('shaar19-live-console'); fetch('/profile-privacy-cache', {cache:'no-store'}).then(r=>r.text())"
      )
      try await self.wait("Console and Network stream events") {
        DevToolsPanelResults.receivedConsoleAndNetwork(shell.events)
      }
      return "Console error and loopback fetch reached the live app event models"
    }
    await check("network-tools") { try await self.proveNetworkTools(shell) }
    await check("network-throttle") {
      try await self.proveNetworkThrottle(target, inspector: inspector)
    }
    await check("application-cookie") {
      shell.cookies.configure(store: self.engine, target: target)
      await shell.cookies.refresh()
      guard let cookie = shell.cookies.cookies.first(where: { $0.name == "inspector-http-only" })
      else {
        throw Failure(
          "Authored HttpOnly fixture cookie missing: \(shell.cookies.failure ?? "no error")")
      }
      shell.cookies.selectedID = cookie.id
      await shell.cookies.save(
        value: "shaar19-edited", secure: cookie.secure, httpOnly: cookie.httpOnly,
        sameSite: cookie.sameSite)
      guard
        shell.cookies.cookies.first(where: { $0.id == cookie.id })?.value
          == "shaar19-edited"
      else {
        throw Failure("Cookie edit did not read back: \(shell.cookies.failure ?? "no error")")
      }
      await shell.cookies.deleteSelected()
      guard !shell.cookies.cookies.contains(where: { $0.id == cookie.id }) else {
        throw Failure("Cookie delete did not read back")
      }
      return "HttpOnly fixture cookie listed, edited, read back, deleted"
    }
    let storage = ApplicationStorageProof(
      application: shell.application, phase2: shell.phase2, inspector: inspector)
    await check("application-local-storage") { try await storage.local() }
    await check("application-session-storage") { try await storage.session() }
    await check("application-indexed-db") { try await storage.indexedDB() }
    await check("application-cache-storage") { try await storage.cache() }
    await check("application-service-worker") { try await storage.serviceWorker() }
    await check("network-rules") {
      try await self.wait("network rules lease") { shell.rules.available }
      shell.rules.createNew()
      shell.rules.draft?.enabled = true
      shell.rules.draft?.method = "GET"
      shell.rules.draft?.url = self.url("/profile-privacy-cache").absoluteString
      shell.rules.draft?.kind = .mock
      shell.rules.draft?.bodyText = "shaar19-mock-response"
      do { try await shell.rules.saveDraft() } catch {
        let rows = shell.rules.rules.map { rule in
          "kind=\(rule.kind.rawValue),url=\(rule.url),body=\(rule.bodyText.utf8.count) bytes"
        }
        throw Failure("Mock rule install failed: \(error.localizedDescription); \(rows)")
      }
      guard shell.rules.activeCount == 1,
        let mocked = try await inspector.evaluate(
          "fetch('/profile-privacy-cache',{cache:'no-store'}).then(r=>r.text())") as? String,
        mocked == "shaar19-mock-response",
        let saved = shell.rules.rules.first
      else { throw Failure("Mock rule did not intercept the page fetch") }
      shell.rules.edit(saved)
      shell.rules.draft?.kind = .redirect
      shell.rules.draft?.redirectURL = self.url("/inspector-tools").absoluteString
      do { try await shell.rules.saveDraft() } catch {
        throw Failure("Redirect rule install failed: \(error.localizedDescription)")
      }
      guard
        let redirected = try await inspector.evaluate(
          "fetch('/profile-privacy-cache',{cache:'no-store'}).then(r=>r.text())") as? String,
        redirected.contains("Page tools fixture"),
        let redirectRule = shell.rules.rules.first
      else { throw Failure("Redirect rule did not return the destination page") }
      shell.rules.edit(redirectRule)
      shell.rules.draft?.kind = .delay
      shell.rules.draft?.redirectURL = ""
      shell.rules.draft?.delayMilliseconds = 450
      do { try await shell.rules.saveDraft() } catch {
        throw Failure("Delay rule install failed: \(error.localizedDescription)")
      }
      guard
        let elapsed = try await inspector.evaluate(
          "(async()=>{const t=performance.now();await fetch('/profile-privacy-cache',{cache:'no-store'});return performance.now()-t})()"
        ) as? Double,
        elapsed >= 350
      else { throw Failure("Delay rule did not hold the page fetch") }
      if let delayRule = shell.rules.rules.first {
        shell.rules.edit(delayRule)
        shell.rules.draft?.kind = .requestHeaders
        shell.rules.draft?.delayMilliseconds = 0
        shell.rules.draft?.url = self.url("/inspector-echo-header").absoluteString
        shell.rules.draft?.headers = [
          ShaarNetworkHeader(name: "X-Shaar-Probe", value: "request-modified")
        ]
        try await shell.rules.saveDraft()
        guard
          let requestValue = try await inspector.evaluate(
            "fetch('/inspector-echo-header',{cache:'no-store'}).then(r=>r.text())") as? String,
          requestValue == "request-modified",
          let requestRule = shell.rules.rules.first
        else { throw Failure("Request header rule did not change the fixture request") }
        shell.rules.edit(requestRule)
        shell.rules.draft?.kind = .responseHeaders
        shell.rules.draft?.headers = [
          ShaarNetworkHeader(name: "X-Shaar-Response", value: "response-modified")
        ]
        try await shell.rules.saveDraft()
        guard
          let responseValue = try await inspector.evaluate(
            "fetch('/inspector-echo-header',{cache:'no-store'}).then(r=>r.headers.get('X-Shaar-Response'))"
          ) as? String,
          responseValue == "response-modified",
          let responseRule = shell.rules.rules.first
        else { throw Failure("Response header rule did not change the fixture response") }
        shell.rules.edit(responseRule)
        shell.rules.draft?.enabled = false
        try await shell.rules.saveDraft()
      }
      return
        "Mock, redirect, 450 ms delay, and request/response headers changed real page fetches; delay observed \(Int(elapsed)) ms"
    }
    await check("viewports") {
      shell.section = .viewports
      do {
        try await self.wait("two rendered viewport frames") {
          shell.viewports.available && shell.viewports.frames.count == 2
            && shell.viewports.frames.allSatisfy { !$0.pngData.isEmpty }
        }
      } catch {
        var nativeOpen = "not attempted"
        if let runtime = self.engine.runtime as? ARCShaarRuntime {
          let requester = ShaarViewportRuntimeRequester(
            runtime: runtime, windowID: self.engine.windowID, contextID: nil)
          do {
            let reply = try await requester.request(
              .viewportOpen, target: target, payload: ["schemaVersion": 1])
            if let leaseID = reply["leaseID"] as? Int {
              defer {
                Task {
                  _ = try? await requester.request(
                    .viewportClose, target: target,
                    payload: ["schemaVersion": 1, "leaseID": leaseID])
                }
              }
              do {
                let added = try await requester.request(
                  .viewportAdd, target: target,
                  payload: [
                    "schemaVersion": 1, "leaseID": leaseID,
                    "preset": "iphone15Pro", "width": 393, "height": 852,
                  ])
                nativeOpen = "added \(added)"
                if let viewportID = added["viewportID"] as? Int {
                  do {
                    let frame = try await requester.request(
                      .viewportFrame, target: target,
                      payload: [
                        "schemaVersion": 1, "leaseID": leaseID, "viewportID": viewportID,
                      ])
                    nativeOpen = "frame keys \(frame.keys.sorted())"
                  } catch { nativeOpen = "frame error: \(error.localizedDescription)" }
                }
              } catch { nativeOpen = "add error: \(error.localizedDescription)" }
            } else {
              nativeOpen = "open reply missing lease: \(reply)"
            }
          } catch { nativeOpen = error.localizedDescription }
        }
        throw Failure(
          "Viewports unavailable: available=\(shell.viewports.available), frames=\(shell.viewports.frames.count), nativeOpen=\(nativeOpen)"
        )
      }
      guard let mobile = shell.viewports.frames.first(where: { $0.preset == .iphone15Pro }) else {
        throw Failure("Mobile viewport missing")
      }
      let beforeInsets = mobile.pngData
      let insets = ShaarViewportInsets(top: 80, right: 0, bottom: 30, left: 0)
      try await shell.viewports.perform(.setSafeArea(mobile.id, insets))
      try await self.wait("safe-area CSS changed the rendered viewport frame") {
        guard let frame = shell.viewports.frames.first(where: { $0.id == mobile.id }) else {
          return false
        }
        return frame.safeArea == insets && !frame.pngData.isEmpty
          && frame.pngData != beforeInsets
      }
      return try await self.proveSyncedViewports(shell)
    }
    await check("masked-repro") {
      do {
        try await self.wait("masked screencast frame", attempts: 120) {
          shell.repro.available
        }
      } catch {
        throw Failure(
          "Masked repro unavailable: stream=\(shell.streamAvailable), recording=\(shell.repro.recording), frames=\(shell.repro.hasMaskedFrames), error=\(shell.repro.failure ?? "none")"
        )
      }
      guard let archive = await shell.repro.capture(to: self.root),
        let contents = try? await ShaarReproBundle.read(at: archive)
      else {
        throw Failure("Masked repro archive not created: \(shell.repro.failure ?? "no error")")
      }
      let dom = String(data: try JSONEncoder().encode(contents.dom), encoding: .utf8) ?? ""
      guard !dom.contains("password-private-fixture"), contents.videoMP4.count > 12,
        !NSApp.windows.contains(where: \.isVisible)
      else { throw Failure("Repro archive leaked form data or opened a window") }
      return "Masked MP4, DOM, HAR, console, environment archived at \(archive.lastPathComponent)"
    }
    await check("elements-live") {
      shell.section = .elements
      do {
        try await self.wait("live DOM tree document") {
          shell.dom.available && shell.dom.rootID != nil && !shell.dom.loading
        }
      } catch {
        let connection = InspectorConnection(engine: self.engine)
        let command: String
        do {
          _ = try await connection.call("DOM.markUndoableState", params: [:], target: target)
          command = "markUndo succeeded"
        } catch {
          command = "markUndo failed: \(error.localizedDescription)"
        }
        throw Failure(
          "Live DOM unavailable: available=\(shell.dom.available), root=\(String(describing: shell.dom.rootID)), loading=\(shell.dom.loading), modelError=\(shell.dom.failure ?? "none"), \(command)"
        )
      }
      guard let body = shell.dom.nodes.values.first(where: { $0.name == "BODY" }) else {
        throw Failure("Live DOM document did not include BODY")
      }
      await shell.dom.toggleExpanded(body.id)
      try await self.wait("BODY children requested") {
        shell.dom.nodes[body.id]?.childrenIDs.isEmpty == false
      }
      _ = try await inspector.evaluate(
        "(()=>{const node=document.createElement('span');node.id='shaar-live-element';node.textContent='LiveDOMProbe';document.body.appendChild(node);return true})()"
      )
      try await self.wait("live DOM insertion event") {
        shell.dom.nodes.values.contains { node in
          node.attributes.contains { $0.name == "id" && $0.value == "shaar-live-element" }
        }
      }
      guard
        let node = shell.dom.nodes.values.first(where: { node in
          node.attributes.contains { $0.name == "id" && $0.value == "shaar-live-element" }
        })
      else { throw Failure("Live DOM node disappeared") }
      shell.dom.select(node.id)
      await shell.dom.setAttribute("data-probe", value: "edited-in-elements")
      guard
        let value = try await inspector.evaluate(
          "document.getElementById('shaar-live-element').getAttribute('data-probe')") as? String,
        value == "edited-in-elements"
      else { throw Failure("Elements attribute edit did not reach the page") }
      return "DOM insertion appeared through the live stream; attribute edit reached the page"
    }
    await check("console-tools") { try await self.proveConsoleTools(shell, inspector: inspector) }
    return try results.finish(
      root: root, phase: phase, engine: engine.runtime.chromiumVersion,
      hidden: NSApp.windows.allSatisfy { !$0.isVisible })
  }

  private func proveSyncedViewports(_ shell: ShaarDevToolsModel) async throws -> String {
    let destination = url("/inspector-viewports")
    let beforeNavigation = viewportPNG(shell)
    try await shell.viewports.perform(.navigate(destination))
    try await wait("synced viewport navigation", attempts: 160) {
      self.viewportsShow(shell, path: "/inspector-viewports", changedFrom: beforeNavigation)
    }
    guard let source = shell.viewports.frames.first(where: { $0.preset == .iphone15Pro }) else {
      throw Failure("Mobile viewport missing after navigation")
    }
    let beforeClick = viewportPNG(shell)
    try await shell.viewports.perform(.click(source.id, x: 48, y: 48))
    try await wait("synced viewport click", attempts: 160) {
      self.viewportsChanged(shell, from: beforeClick)
    }
    let beforeScroll = viewportPNG(shell)
    try await shell.viewports.perform(.scroll(source.id, deltaX: 0, deltaY: 640))
    try await wait("synced viewport scroll", attempts: 160) {
      self.viewportsChanged(shell, from: beforeScroll)
    }
    let paths = Set(shell.viewports.frames.map(\.url.path))
    guard paths == ["/inspector-viewports"], shell.viewports.frames.count == 2 else {
      throw Failure("Viewport navigation diverged: \(paths)")
    }
    return "Safe area, navigation, click, and scroll changed both offscreen viewport frames"
  }

  private func viewportPNG(_ shell: ShaarDevToolsModel) -> [UUID: Data] {
    Dictionary(uniqueKeysWithValues: shell.viewports.frames.map { ($0.id, $0.pngData) })
  }

  private func viewportsChanged(
    _ shell: ShaarDevToolsModel, from previous: [UUID: Data]
  ) -> Bool {
    let frames = shell.viewports.frames
    guard frames.count >= 2, frames.count == previous.count else { return false }
    return frames.allSatisfy { frame in
      guard let before = previous[frame.id] else { return false }
      return !before.isEmpty && !frame.pngData.isEmpty && frame.pngData != before
    }
  }

  private func viewportsShow(
    _ shell: ShaarDevToolsModel, path: String, changedFrom previous: [UUID: Data]
  ) -> Bool {
    guard viewportsChanged(shell, from: previous) else { return false }
    return shell.viewports.frames.allSatisfy { $0.url.path == path }
  }

  private func proveNetworkTools(_ shell: ShaarDevToolsModel) async throws -> String {
    try await wait("privacy cache request finished") {
      shell.network.requests(from: shell.events).contains { row in
        row.url.contains("/profile-privacy-cache") && row.status != nil
      }
    }
    guard
      let row = shell.network.requests(from: shell.events).first(where: {
        $0.url.contains("/profile-privacy-cache")
      })
    else { throw Failure("Loopback fetch did not reach the Network model") }
    shell.network.filter = .fetch
    shell.network.statusFilter = .success
    shell.network.search = "privacy-cache"
    guard shell.network.visibleRequests(from: shell.events).contains(where: { $0.id == row.id })
    else { throw Failure("Type, status, and text filters hid the loopback fetch") }
    shell.network.statusFilter = .clientError
    guard !shell.network.visibleRequests(from: shell.events).contains(where: { $0.id == row.id })
    else { throw Failure("4xx filter kept a successful request") }
    shell.network.filter = .all
    shell.network.statusFilter = .any
    shell.network.search = ""
    let curl = shell.network.curlCommand(for: row)
    let fetch = shell.network.fetchCommand(for: row)
    guard curl.contains("profile-privacy-cache"), fetch.hasPrefix("fetch(") else {
      throw Failure("cURL or fetch copy missed the request")
    }
    let body = try await responseBody(shell, requestID: row.id)
    let har = String(
      decoding: ShaarNetworkHAR.document(
        requests: shell.network.exportRequests(from: shell.events)),
      as: UTF8.self)
    guard har.contains("profile-privacy-cache"), har.contains(body) else {
      throw Failure("HAR export missed the request or its body")
    }
    return "Type, status, and text filters, response body, cURL, fetch, and HAR matched the live fetch"
  }

  private func responseBody(_ shell: ShaarDevToolsModel, requestID: String) async throws -> String {
    var body = ""
    for _ in 0..<15 {
      await shell.network.loadResponseBody(id: requestID)
      body =
        shell.network.exportRequests(from: shell.events).first { $0.id == requestID }?.responseBody
        ?? ""
      if !body.isEmpty { return body }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Response body did not load for the loopback fetch")
  }

  private func proveNetworkThrottle(
    _ target: SiteControlTarget, inspector: InspectorModel
  ) async throws -> String {
    let developer = engine.developerModel(for: target)
    try await wait("developer session idle") { !developer.applying }
    try developer.retainDeveloperSession()
    let baseline = try await elapsedFetch(inspector, path: "/inspector-echo-header?base=1")
    let slowed: TimeInterval
    do {
      try await ShaarNetworkConditions.applyThrottle(.slow3G) { method, params in
        _ = try await developer.call(method, params: params)
      }
      slowed = try await elapsedFetch(inspector, path: "/inspector-echo-header?slow=1")
    } catch {
      try? await ShaarNetworkConditions.applyThrottle(.none) { method, params in
        _ = try await developer.call(method, params: params)
      }
      throw error
    }
    try await ShaarNetworkConditions.applyThrottle(.none) { method, params in
      _ = try await developer.call(method, params: params)
    }
    guard slowed >= baseline + 0.25 else {
      throw Failure(
        "Slow 3G added \(slowed - baseline)s over a \(baseline)s baseline")
    }
    let cacheDetail = await cacheDisabledDetail(developer)
    let added = Int(((slowed - baseline) * 1_000).rounded())
    return "Slow 3G delayed a loopback fetch by \(added) ms. \(cacheDetail)"
  }

  private func cacheDisabledDetail(_ developer: DeveloperPageModel) async -> String {
    do {
      try await ShaarNetworkConditions.applyCacheDisabled(true) { method, params in
        _ = try await developer.call(method, params: params)
      }
      try await ShaarNetworkConditions.applyCacheDisabled(false) { method, params in
        _ = try await developer.call(method, params: params)
      }
      return "Disable cache was accepted by this engine."
    } catch {
      return
        "Disable cache is not in this engine (command 62): \(error.localizedDescription). Ready for engine build."
    }
  }

  private func elapsedFetch(_ inspector: InspectorModel, path: String) async throws -> TimeInterval
  {
    let started = Date()
    _ = try await inspector.evaluate("fetch('\(path)',{cache:'no-store'}).then(r=>r.text())")
    return Date().timeIntervalSince(started)
  }

  private func proveConsoleTools(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel
  ) async throws -> String {
    _ = try await inspector.evaluate("console.error('shaar19-live-console')")
    try await wait("console tools error") {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("shaar19-live-console")
      }
    }
    shell.console.command = "({probe:1124, ok:true})"
    await shell.console.submit { expression in
      let reply = try await inspector.call(
        "Runtime.evaluate",
        params: [
          "expression": expression,
          "objectGroup": ShaarConsoleModel.objectGroup,
          "generatePreview": true,
          "awaitPromise": true,
          "silent": true,
        ])
      return try ShaarConsoleModel.evaluation(from: reply)
    }
    guard
      let entry = shell.console.rows(from: shell.consoleEvents).last(where: {
        $0.event.objectID != nil
      })?.event,
      let objectID = entry.objectID,
      entry.previewProperties.contains(where: { $0.name == "probe" })
    else { throw Failure("Evaluated object did not keep a preview or object id") }
    let properties = try await inspector.call(
      "Runtime.getProperties", params: ["objectId": objectID, "ownProperties": true])
    guard ShaarConsoleModel.parseProperties(properties).contains(where: { $0.name == "probe" })
    else { throw Failure("Runtime.getProperties did not expand the evaluated object") }
    shell.console.searchUsesRegex = true
    shell.console.search = "shaar19-live-console"
    guard
      shell.console.rows(from: shell.consoleEvents).contains(where: {
        $0.event.message.contains("shaar19-live-console")
      })
    else { throw Failure("Regular expression filter missed the live console error") }
    shell.console.search = "("
    guard shell.console.regexIsInvalid, shell.console.rows(from: shell.consoleEvents).isEmpty
    else { throw Failure("Invalid regular expression still matched console rows") }
    shell.console.searchUsesRegex = false
    shell.console.search = ""
    shell.console.level = .error
    let errors = shell.console.rows(from: shell.consoleEvents)
    guard errors.allSatisfy({ $0.event.level == .error }),
      errors.contains(where: { $0.event.message.contains("shaar19-live-console") })
    else { throw Failure("Error level filter did not keep only console errors") }
    shell.console.level = nil
    guard shell.console.history.contains("({probe:1124, ok:true})") else {
      throw Failure("Command history did not keep the evaluation")
    }
    shell.console.preserveLog = true
    shell.updateTarget(shell.target, committed: true)
    try await wait("panel stream restored") { shell.streamAvailable }
    guard
      shell.console.rows(from: shell.consoleEvents).contains(where: {
        $0.event.message.contains("shaar19-live-console")
      })
    else { throw Failure("Preserve log dropped the console error on navigation") }
    let history = shell.console.history
    shell.console.clearEntries()
    guard
      !shell.console.rows(from: shell.consoleEvents).contains(where: {
        $0.event.message.contains("shaar19-live-console")
      })
    else { throw Failure("Clear left the preserved console error in the log") }
    guard shell.console.history == history else { throw Failure("Clear dropped command history") }
    shell.console.preserveLog = false
    return
      "Evaluation expanded, regex and level filters matched, preserve log survived navigation, and clear kept history"
  }

  private func check(_ name: String, _ operation: () async throws -> String) async {
    await results.check(name, operation)
  }

  private func url(_ path: String) -> URL {
    DevToolsPanelResults.fixtureURL(path, from: fixture)
  }

  private func wait(
    _ message: String, attempts: Int = 80, _ condition: () -> Bool
  ) async throws {
    try await results.wait(message, attempts: attempts, condition)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}

/// Stores every panel outcome before enforcing the native fixture gate.
@MainActor final class DevToolsPanelResults {
  static let requiredPanels: Set<String> = [
    "console-network", "network-tools", "network-throttle", "application-cookie",
    "application-local-storage", "application-session-storage", "application-indexed-db",
    "application-cache-storage", "application-service-worker", "network-rules", "viewports",
    "masked-repro", "elements-live", "console-tools",
  ]

  private var entries: [String: [String: Any]] = [:]

  func check(_ name: String, _ operation: () async throws -> String) async {
    do {
      entries[name] = ["passed": true, "detail": try await operation()]
    } catch {
      entries[name] = ["passed": false, "detail": error.localizedDescription]
    }
  }

  func finish(root: URL, phase: String, engine: String, hidden: Bool) throws -> [String] {
    let report: [String: Any] = [
      "phase": phase, "engine": engine, "hidden": hidden, "results": entries,
    ]
    let file = root.appending(path: "\(phase)-devtools-panels.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: file, options: .atomic)

    guard hidden else { throw Failure("DevTools panel probe opened a visible window") }
    guard Set(entries.keys) == Self.requiredPanels else {
      throw Failure("DevTools panel probe omitted a required panel; see \(file.lastPathComponent)")
    }
    guard entries.values.allSatisfy({ $0["passed"] as? Bool == true }) else {
      throw Failure("One or more DevTools panels failed; see \(file.lastPathComponent)")
    }
    return entries.keys.sorted().map { "\($0): \(entries[$0]?["detail"] as? String ?? "passed")" }
  }

  static func fixtureURL(_ path: String, from fixture: URL) -> URL {
    var parts = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    parts.path = path
    parts.query = nil
    return parts.url!
  }

  static func receivedConsoleAndNetwork(_ events: [ShaarDevToolsEvent]) -> Bool {
    let console = events.contains { item in
      guard case .console(let event) = item else { return false }
      return event.message.contains("shaar19-live-console")
    }
    let network = events.contains { item in
      guard case .network(let event) = item else { return false }
      return event.url.contains("/profile-privacy-cache")
    }
    return console && network
  }

  func wait(_ message: String, attempts: Int, _ condition: () -> Bool) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out: \(message)")
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
