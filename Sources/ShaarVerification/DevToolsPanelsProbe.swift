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
    guard let target = engine.siteControlTarget, target.tabID == tab else {
      throw Failure("No selected page for Shaar DevTools")
    }
    engine.toggleDeveloperTools()
    guard let shell = engine.shaarDevTools[tab], shell.isOpen,
      let inspector = engine.inspectors[tab]
    else { throw Failure("Shaar DevTools menu did not open the Shaar shell") }
    let chromiumDockClosed = engine.runtime.devToolsView(forTabID: tab.uuidString) == nil
    try await wait("live panel lease") { shell.streamAvailable }

    await check("f12-route") {
      guard shell.isOpen, chromiumDockClosed else {
        throw Failure("The Shaar DevTools command opened the Chromium dock")
      }
      guard Self.f12OpensShaarDevTools() else {
        throw Failure("F12 no longer maps to Shaar DevTools")
      }
      return "Shaar DevTools opened the Shaar shell and left the Chromium dock closed. "
        + "F12 maps to that command."
    }
    await check("shell-defaults") {
      try self.proveShellDefaults(shell)
    }
    await check("console-network") {
      _ = try await inspector.evaluate(
        "console.error('shaar19-live-console'); fetch('/profile-privacy-cache', {cache:'no-store'}).then(r=>r.text())"
      )
      try await self.wait("Console and Network stream events") {
        DevToolsPanelResults.receivedConsoleAndNetwork(shell.events)
      }
      return "Console error and loopback fetch reached the live app event models"
    }
    await check("network-row") {
      try await self.wait("live network row columns") {
        self.finishedPrivacyRow(shell) != nil
      }
      guard let row = self.finishedPrivacyRow(shell) else {
        throw Failure("Live network row lost its columns")
      }
      let size = row.encodedBytes ?? 0
      let millis = Int(((row.duration ?? 0) * 1_000).rounded())
      return "\(row.method) \(row.name) \(row.resource.rawValue) \(size) bytes \(millis) ms"
    }
    await check("console-repeat") {
      _ = try await inspector.evaluate(
        "console.error('shaar-repeat-copy'); console.error('shaar-repeat-copy'); true"
      )
      try await self.wait("repeated console row") {
        self.repeatedCopyRow(shell) != nil
      }
      guard let row = self.repeatedCopyRow(shell) else {
        throw Failure("Repeated console row disappeared")
      }
      let copy = shell.console.agentCopyText(for: row)
      guard copy.contains("shaar-repeat-copy"),
        copy.contains("Repeated \(row.count) times")
      else {
        throw Failure("Copy for agent missed the repeated console row")
      }
      let flat = copy.replacingOccurrences(of: "\n", with: " | ")
      return "Repeated \(row.count) times. Stack frames \(row.event.stack.count). \(flat)"
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
      let remainder = try await DevToolsNetworkRulesProof(
        engine: self.engine, store: self.store, shell: shell, inspector: inspector,
        space: space, tab: tab, root: self.root, fixture: self.fixture
      ).run()
      return
        "Mock, redirect, 450 ms delay, and request/response headers changed real page fetches; delay observed \(Int(elapsed)) ms. \(remainder)"
    }
    await check("source-bytes") {
      try await DevToolsSourceBytesProof(
        shell: shell, inspector: inspector, fixture: self.fixture
      ).run()
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
    await check("elements-inspector") {
      guard shell.section == .elements, inspector.isOpen, inspector.target.tabID == tab,
        self.engine.inspectors[tab] === inspector, shell.dom.available,
        shell.dom.nodes.values.contains(where: { $0.name == "BODY" })
      else { throw Failure("Elements is not using this tab's Inspector") }
      let marker =
        try await inspector.evaluate(
          "document.getElementById('shaar-live-element') !== null") as? Bool
      guard marker == true else { throw Failure("This tab's Inspector lost the Elements node") }
      let path = inspector.target.url.path
      return "Elements is open on this tab's Inspector at \(path)"
    }
    await check("elements-scale") {
      try await DevToolsDOMScaleProof(shell: shell, inspector: inspector).run()
    }
    await check("split-shell") {
      try await self.proveSplitShells(firstTab: tab, firstShell: shell)
    }
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

  private static func f12OpensShaarDevTools() -> Bool {
    let f12 = ShaarDevToolsShortcut.isF12(keyCode: 111, modifiers: [])
    let chord = ShaarDevToolsShortcut.isF12(
      keyCode: 111, modifiers: [.command, .option, .shift])
    let shaar = ShortcutCatalog.shortcut(for: .developerTools)
    let chromium = ShortcutCatalog.shortcut(for: .chromiumDeveloperTools)
    guard f12, !chord, shaar?.key == "i", chromium?.key == "i" else { return false }
    return shaar?.modifiers == [.command, .option]
      && chromium?.modifiers == [.command, .option, .shift]
  }

  private func finishedPrivacyRow(_ shell: ShaarDevToolsModel) -> ShaarNetworkRequest? {
    shell.network.requests(from: shell.events).first { row in
      row.url.contains("/profile-privacy-cache")
        && row.method == "GET"
        && row.name == "profile-privacy-cache"
        && row.encodedBytes != nil
        && row.duration != nil
    }
  }

  private func repeatedCopyRow(_ shell: ShaarDevToolsModel) -> ShaarConsoleRow? {
    shell.console.rows(from: shell.consoleEvents).first { row in
      row.event.message == "shaar-repeat-copy" && row.count >= 2
    }
  }

  private func proveSplitShells(
    firstTab: UUID, firstShell: ShaarDevToolsModel
  ) async throws -> String {
    let existing = Set(store.session.selectedSpace.tabs.map(\.id))
    store.perform(.open(url("/account")))
    do {
      try await wait("second pane page") { self.secondPaneTab(existing: existing) != nil }
    } catch {
      throw Failure(secondPaneFailure(existing: existing))
    }
    guard let second = secondPaneTab(existing: existing) else {
      throw Failure("Second pane tab disappeared")
    }
    store.splitTabs(firstTab, second)
    guard let split = store.selectedSplit, split.tabIDs.contains(firstTab),
      split.tabIDs.contains(second)
    else { throw Failure("The two pages did not share a split") }
    store.focusSplitTab(second)
    try await wait("second pane selected") { self.engine.siteControlTarget?.tabID == second }
    guard let secondTarget = engine.siteControlTarget, secondTarget.tabID == second else {
      throw Failure("Second pane was not the selected page")
    }
    guard engine.showDeveloperTools(for: secondTarget),
      let secondShell = engine.shaarDevTools[second], secondShell.isOpen,
      let secondInspector = engine.inspectors[second]
    else { throw Failure("Second pane did not open its own shell") }
    guard firstShell.isOpen, firstShell !== secondShell else {
      throw Failure("Split panes shared one shell")
    }
    try await wait("second pane shell stream") { secondShell.streamAvailable }
    _ = try await secondInspector.evaluate("console.error('shaar-split-pane'); true")
    try await wait("second pane console event") { self.splitMarker(secondShell) }
    guard !splitMarker(firstShell) else {
      throw Failure("Split pane console event crossed shells")
    }
    secondShell.close()
    guard !secondShell.isOpen, firstShell.isOpen else {
      throw Failure("Closing one pane shell closed the other")
    }
    return "Two split panes kept separate shells"
  }

  private func secondPaneTab(existing: Set<UUID>) -> UUID? {
    store.session.selectedSpace.tabs.map(\.id).first { id in
      guard !existing.contains(id), engine.liveTabs.contains(id),
        engine.pages[id]?.loading == false
      else { return false }
      return engine.runtime.windowID(forTabID: id.uuidString) == engine.windowID
    }
  }

  private func secondPaneFailure(existing: Set<UUID>) -> String {
    let described = store.session.selectedSpace.tabs.map(\.id).filter { !existing.contains($0) }
      .map { id -> String in
        let loading = engine.pages[id]?.loading == true
        let live = engine.liveTabs.contains(id)
        let window = engine.runtime.windowID(forTabID: id.uuidString) ?? "none"
        return "\(id.uuidString.prefix(8)) live=\(live) loading=\(loading) window=\(window)"
      }
    return "Second pane did not load: \(described.joined(separator: "; "))"
  }

  private func splitMarker(_ shell: ShaarDevToolsModel) -> Bool {
    shell.events.contains { event in
      guard case .console(let entry) = event else { return false }
      return entry.message.contains("shaar-split-pane")
    }
  }

  private static let unavailableCopy = [
    "Live DOM tree is unavailable for this tab",
    "Live component tree is unavailable for this tab",
    "Live Application is unavailable for this tab",
    "Live Performance is unavailable for this tab",
    "Live Sources are unavailable for this tab",
    "Repro capture needs engine support",
    "Live Viewports need engine support",
    "WebKit comparison is unavailable for this tab",
    "Live console and network are unavailable for this tab",
    "Use Chromium DevTools until the live stream is available.",
    "Open Chromium DevTools",
    "Application data is unavailable for this tab",
    "Performance data is unavailable for this tab",
    "Sources are unavailable for this tab",
    "Console commands are unavailable for this tab",
  ]

  private static func namesEngineVersion(_ text: String) -> Bool {
    if text.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil { return true }
    return text.range(of: #"shaar\.\d+"#, options: .regularExpression) != nil
  }

  private func proveShellDefaults(_ shell: ShaarDevToolsModel) throws -> String {
    guard shell.dock == .right else {
      throw Failure("Shaar DevTools opened docked to \(shell.dock.rawValue)")
    }
    for language in BrowserLanguage.allCases {
      for line in Self.unavailableCopy {
        let text = BrowserLocalization.string(line, table: "Shell", language: language)
        if Self.namesEngineVersion(text) {
          throw Failure("Unavailable copy names an engine version: \(text)")
        }
      }
    }
    return "Docked to the right. Unavailable copy does not name an engine version."
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
    "f12-route", "shell-defaults", "console-network", "network-row",
    "console-repeat", "split-shell", "application-cookie",
    "application-local-storage",
    "application-session-storage", "application-indexed-db", "application-cache-storage",
    "application-service-worker", "network-rules", "source-bytes", "viewports",
    "masked-repro", "elements-live", "elements-inspector", "elements-scale",
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
