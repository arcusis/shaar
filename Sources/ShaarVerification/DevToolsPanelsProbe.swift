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
    await check("security") {
      try await self.proveSecurity(shell: shell)
    }
    await check("audits") {
      try await self.proveAudits(shell: shell, inspector: inspector)
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
    await check("network-tools") { try await self.proveNetworkTools(shell) }
    await check("network-throttle") {
      try await self.proveNetworkThrottle(target, inspector: inspector)
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
    await check("issues") {
      try await self.proveIssues(shell: shell, inspector: inspector)
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
    await check("css") {
      try await self.proveCSS(shell: shell)
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
      let synced = try await self.proveSyncedViewports(shell)
      let presets = try await self.proveViewportPresets(shell)
      return "\(synced). \(presets)"
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
      shell.dom.search = "#shaar-live-element"
      await shell.dom.performSearch()
      guard let label = shell.dom.matchCountLabel, !shell.dom.matchOrder.isEmpty,
        let selected = shell.dom.selectedID, shell.dom.matchOrder.contains(selected),
        shell.dom.nodes[selected] != nil
      else {
        throw Failure(
          "DOM search missed the live element: \(shell.dom.failure ?? "none") order=\(shell.dom.matchOrder) selected=\(String(describing: shell.dom.selectedID))"
        )
      }
      let visible = shell.dom.rows.contains { $0.id == selected }
      guard visible else {
        throw Failure("DOM search hit \(selected) stayed outside the visible tree")
      }
      await shell.dom.stepSearchMatch(forward: true)
      await shell.dom.stepSearchMatch(forward: false)
      guard shell.dom.selectedID == selected, shell.dom.matchOrder.contains(selected) else {
        throw Failure("DOM search did not keep the current hit after wrapping")
      }
      guard let beforeHide = shell.dom.nodes[selected], !shell.dom.showsHidden(beforeHide) else {
        throw Failure("Live element was already marked hidden")
      }
      await shell.dom.toggleVisibility()
      guard let hiddenNode = shell.dom.nodes[selected], shell.dom.showsHidden(hiddenNode) else {
        throw Failure("Tree did not mark the element hidden: \(shell.dom.failure ?? "none")")
      }
      guard
        let hidden = try await inspector.evaluate(
          "getComputedStyle(document.getElementById('shaar-live-element')).visibility") as? String,
        hidden == "hidden"
      else { throw Failure("H did not set visibility:hidden on the page") }
      await shell.dom.toggleVisibility()
      guard let shownNode = shell.dom.nodes[selected], !shell.dom.showsHidden(shownNode) else {
        throw Failure("Second H left the hidden mark on the tree")
      }
      guard
        let restored = try await inspector.evaluate(
          "getComputedStyle(document.getElementById('shaar-live-element')).visibility") as? String,
        restored == "visible"
      else { throw Failure("Second H did not restore visibility") }
      _ = try await inspector.evaluate(
        "(()=>{const host=document.createElement('div');host.id='shaar-copy-host';const first=document.createElement('em');const second=document.createElement('em');host.append(first,second);document.body.appendChild(host);return true})()"
      )
      try await reloadBodyChildren(shell.dom)
      try await self.wait("copy host in the DOM model") {
        shell.dom.nodes.values.contains { node in
          node.attributes.contains { $0.name == "id" && $0.value == "shaar-copy-host" }
        }
      }
      guard
        let host = shell.dom.nodes.values.first(where: { node in
          node.attributes.contains { $0.name == "id" && $0.value == "shaar-copy-host" }
        })
      else { throw Failure("Copy host disappeared") }
      await shell.dom.toggleExpanded(host.id)
      try await self.wait("copy host children") {
        let children = shell.dom.nodes[host.id]?.childrenIDs ?? []
        return children.compactMap { shell.dom.nodes[$0] }.filter { $0.name == "EM" }.count == 2
      }
      guard
        let second = shell.dom.nodes[host.id]?.childrenIDs.compactMap({ shell.dom.nodes[$0] })
          .last(where: { $0.name == "EM" })
      else { throw Failure("Second em was not loaded") }
      await shell.dom.prepareCopyPath(for: second.id)
      guard let live = await inspector.pathsForDOMNode(second.id) else {
        throw Failure("Inspector did not compute a selector for the second em")
      }
      let css = shell.dom.selector(for: second.id)
      let xpath = shell.dom.xpath(for: second.id)
      guard css == live.css, xpath == live.xpath, css.contains("nth-of-type(2)"),
        xpath.contains("[2]")
      else {
        throw Failure(
          "Copy paths diverged: model css=\(css) xpath=\(xpath); inspector css=\(live.css) xpath=\(live.xpath)"
        )
      }
      return
        "DOM insertion appeared through the live stream; attribute edit reached the page; search reported \(label); H toggled visibility; copy paths matched \(css)"
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
    await check("console-tools") {
      try await self.proveConsoleTools(shell, inspector: inspector)
    }
    await check("memory") {
      try await self.proveMemory(shell, target: target)
    }
    await check("performance-recording") {
      // Split-shell closes the shared panel lease. Focus this tab and open it again.
      try await self.restoreInspectorToolsLease(shell, tab: tab)
      shell.section = .performance
      // The long-task command installs its observer on the first read. Tasks
      // that already finished are not in the timeline buffer, so that read has
      // to finish before the page timer runs.
      try await self.refreshPerformance(shell.performance)
      shell.performance.startRecording()
      let observed = try await inspector.evaluate("window.__shaarRunLongTask()") as? String
      var refreshes = 0
      while shell.performance.recordedTasks.isEmpty && refreshes < 8 {
        try await self.refreshPerformance(shell.performance)
        refreshes += 1
        if shell.performance.recordedTasks.isEmpty {
          try await Task.sleep(for: .milliseconds(50))
        }
      }
      _ = try await inspector.evaluate(
        "document.getElementById('shift').style.paddingTop='200px'")
      try await self.wait("buffered vitals or a layout shift", attempts: 40) {
        shell.performance.fcpMilliseconds != nil || shell.performance.ttfbMilliseconds != nil
          || shell.performance.cls > 0 || shell.performance.lcpMilliseconds != nil
      }
      try await self.refreshPerformance(shell.performance)
      shell.performance.stopRecording()
      guard shell.performance.capture == .stopped else {
        throw Failure("Performance recording did not stop")
      }
      guard shell.performance.failure == nil else {
        throw Failure("Performance refresh failed: \(shell.performance.failure ?? "")")
      }
      guard !shell.performance.recordedTasks.isEmpty else {
        throw Failure(
          "No main-thread long tasks were recorded. pageTimer=\(observed ?? "nil") refreshes=\(refreshes) metrics=\(shell.performance.metrics)"
        )
      }
      let vitals = await self.provePageVitals(
        shell, target: target, tab: tab, inspector: inspector)
      let inp = shell.performance.inpMilliseconds.map { String($0) } ?? "unavailable"
      let lcp = shell.performance.lcpMilliseconds.map { String($0) } ?? "unavailable"
      return
        "Recorded \(shell.performance.recordedTasks.count) main-thread tasks; LCP=\(lcp) CLS=\(shell.performance.cls) INP=\(inp)\(vitals)"
    }
    await check("sources-lite") {
      try await self.restoreInspectorToolsLease(shell, tab: tab)
      shell.section = .sources
      await shell.sources.refresh()
      guard shell.sources.failure == nil else {
        throw Failure("Resource tree failed: \(shell.sources.failure ?? "")")
      }
      guard
        shell.sources.resources.contains(where: { $0.url.contains("inspector-source-sample.js") }),
        shell.sources.treeRows.contains(where: { $0.resourceURL == nil })
      else {
        throw Failure(
          "File tree missed the sample script: \(shell.sources.resources.map(\.url))")
      }
      guard
        let sample = shell.sources.resources.first(where: {
          $0.name == "inspector-source-sample.js"
        })
      else { throw Failure("Sample script row disappeared") }
      await shell.sources.select(sample)
      shell.sources.prettyPrint = true
      guard shell.sources.displayedContent?.contains("shaarSample") == true,
        shell.sources.displayedContent?.contains("\n") == true
      else {
        throw Failure("Pretty print did not format the sample script")
      }
      shell.sources.contentQuery = "shaarSample"
      shell.sources.revealCurrentMatch()
      guard shell.sources.matchLines.isEmpty == false else {
        throw Failure("In-file search missed shaarSample")
      }
      _ = try await inspector.evaluate("shaarThrowForSources()")
      try await self.wait("console stack for the fixture function") {
        shell.events.contains { event in
          guard case .console(let row) = event else { return false }
          return row.message.contains("shaar-source-jump") && !row.stack.isEmpty
        }
      }
      guard
        let frame = shell.events.compactMap({ event -> ShaarConsoleFrame? in
          guard case .console(let row) = event else { return nil }
          return row.stack.first { $0.source.contains("inspector-source-sample.js") }
        }).first,
        let location = ShaarConsoleLocations.parse(frame.source)
      else { throw Failure("Console stack did not include the sample script") }
      let revealed = await shell.sources.reveal(url: location.url, line: location.line)
      guard revealed, let line = shell.sources.highlightedLine,
        shell.sources.displayedLines?[line].contains("shaarThrowForSources") == true
      else {
        let lines = shell.sources.displayedLines?.count ?? -1
        throw Failure(
          "Sources did not open \(location.source): \(shell.sources.sourceFailure ?? "no error"); lines=\(lines) binary=\(shell.sources.binary) load=\(shell.sources.failure ?? "none")"
        )
      }
      return "File tree, pretty print, search, and console line \(location.line) opened read-only"
    }
    return try results.finish(
      root: root, phase: phase, engine: engine.runtime.chromiumVersion,
      hidden: NSApp.windows.allSatisfy { !$0.isVisible })
  }

  private func proveMemory(_ shell: ShaarDevToolsModel, target: SiteControlTarget) async throws
    -> String
  {
    let summary = try ShaarHeapSnapshotReader.summary(from: ShaarMemoryFixture.snapshotData())
    guard summary.nodeCount == 5, summary.totalBytes == 4800,
      summary.constructors.first?.name == "Window"
    else { throw Failure("Heap fixture summary did not match") }
    let allocated = try ShaarHeapSnapshotReader.allocations(
      from: ShaarMemoryFixture.allocationProfileData())
    guard allocated.first?.name == "HTMLDivElement", allocated.first?.selfBytes == 1500 else {
      throw Failure("Allocation fixture did not match")
    }
    let developer = engine.developerModel(for: target)
    shell.memory.adoptLiveTransport(developer)
    await shell.memory.takeSnapshot()
    if shell.memory.support == .needsEngine {
      for language in BrowserLanguage.allCases {
        let text = BrowserLocalization.string(
          "Live heap snapshots need engine support", table: "Shell", language: language)
        if Self.namesEngineVersion(text) {
          throw Failure("Memory gate names an engine version")
        }
      }
      return
        "Heap fixture is 4800 bytes across 5 nodes. Live snapshot is waiting on the engine build."
    }
    guard let live = shell.memory.snapshot, live.nodeCount > 0 else {
      throw Failure(shell.memory.failure ?? "Live heap snapshot was empty")
    }
    return
      "Live heap snapshot has \(live.nodeCount) nodes and \(live.totalBytes) bytes. Fixture summary matched."
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

  private func proveViewportPresets(_ shell: ShaarDevToolsModel) async throws -> String {
    guard shell.viewports.frames.count == 2 else {
      throw Failure("Expected two viewports before adding presets")
    }
    let portrait = ShaarViewportInsets(top: 24, right: 0, bottom: 20, left: 0)
    let landscape = ShaarViewportInsets(top: 0, right: 24, bottom: 0, left: 20)
    try await shell.viewports.perform(.add(.ipad))
    try await wait("iPad viewport frame", attempts: 160) {
      self.renderedPreset(
        shell, .ipad, size: (820, 1180), orientation: .portrait, safeArea: portrait)
    }
    guard let ipad = shell.viewports.frames.first(where: { $0.preset == .ipad }) else {
      throw Failure("iPad viewport missing after its frame arrived")
    }
    try await shell.viewports.perform(.rotate(ipad.id))
    try await wait("rotated iPad viewport frame", attempts: 160) {
      self.renderedPreset(
        shell, .ipad, size: (1180, 820), orientation: .landscape, safeArea: landscape)
    }
    try await shell.viewports.perform(.rotate(ipad.id))
    try await wait("iPad viewport restored to portrait", attempts: 160) {
      self.renderedPreset(
        shell, .ipad, size: (820, 1180), orientation: .portrait, safeArea: portrait)
    }
    try await shell.viewports.perform(.add(.desktop1440))
    try await wait("Desktop 1440 viewport frame", attempts: 160) {
      self.renderedPreset(
        shell, .desktop1440, size: (1440, 900), orientation: .portrait, safeArea: .zero)
    }
    guard !NSApp.windows.contains(where: \.isVisible) else {
      throw Failure("Viewport preset probe opened a window")
    }
    return "iPad rendered 820x1180, rotated to 1180x820, and returned to portrait. "
      + "Desktop 1440 rendered 1440x900"
  }

  private func renderedPreset(
    _ shell: ShaarDevToolsModel, _ preset: ShaarViewportPreset, size: (Int, Int),
    orientation: ShaarViewportOrientation, safeArea: ShaarViewportInsets
  ) -> Bool {
    guard let frame = shell.viewports.frames.first(where: { $0.preset == preset }),
      let actual = pngSize(frame.pngData)
    else {
      return false
    }
    return frame.orientation == orientation && frame.safeArea == safeArea && actual == size
  }

  private func pngSize(_ data: Data) -> (Int, Int)? {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count >= 24, data.starts(with: signature) else { return nil }
    return (pngDimension(data, at: 16), pngDimension(data, at: 20))
  }

  private func pngDimension(_ data: Data, at offset: Int) -> Int {
    let bytes = [UInt8](data[offset..<(offset + 4)])
    return (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
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
    return
      "Type, status, and text filters, response body, cURL, fetch, and HAR matched the live fetch"
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
        "Disable cache is not in this engine (command 69): \(error.localizedDescription). Ready for engine build."
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
    let stackNote = try await liveConsoleStackNote(shell, inspector: inspector)
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
      "Evaluation expanded, regex and level filters matched, preserve log survived navigation, and clear kept history. "
      + stackNote
  }

  private func liveConsoleStackNote(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel
  ) async throws -> String {
    _ = try await inspector.evaluate(
      "(function shaarStackProbe(){ console.error('shaar-stack-probe'); return true })()")
    try await wait("console stack probe") {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("shaar-stack-probe")
      }
    }
    guard
      let frame = shell.console.rows(from: shell.consoleEvents).first(where: {
        $0.event.message.contains("shaar-stack-probe")
      })?.event.stack.first
    else {
      return "Live stack is absent on this engine. Ready for engine build."
    }
    return "Live stack \(frame.function) \(frame.source)."
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

  private func proveSecurity(shell: ShaarDevToolsModel) async throws -> String {
    let previous = shell.section
    defer { shell.section = previous }
    shell.section = .security
    let level = engineLevel(shell)
    await shell.refreshSecurity()
    guard level == "insecure", shell.securitySummary.connection == .http,
      shell.securitySummary.certificate == nil
    else {
      throw Failure(
        "Security summary level=\(level ?? "nil") connection=\(connectionName(shell.securitySummary.connection)) certificate=\(shell.securitySummary.certificate != nil)"
      )
    }
    return "HTTP page is not secure. Engine level insecure. No certificate on this connection."
  }

  private func proveCSS(shell: ShaarDevToolsModel) async throws -> String {
    let previous = shell.section
    defer { shell.section = previous }
    shell.section = .cssOverview
    try await wait("phase 2 for CSS") { shell.phase2.available }
    var matched = false
    for _ in 0..<8 {
      await shell.cssOverview.reload(force: true)
      if cssOverviewMatches(shell.cssOverview.summary) {
        matched = true
        break
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    guard matched else {
      let detail = await cssDiagnostic(shell)
      throw Failure("CSS overview missed the fixture sheets. \(detail)")
    }
    let summary = shell.cssOverview.summary
    guard let color = summary.colors.first(where: { $0.label.lowercased().contains("5b21b6") }),
      color.sheets.contains(where: { $0.contains("shaar-css-overview.css") }),
      color.sheets.allSatisfy({ !$0.contains("shaar-css-empty.css") }),
      summary.examined > Set(summary.contributingSheets).count
    else {
      let detail = await cssDiagnostic(shell)
      throw Failure("CSS sheet filter is wrong. \(detail)")
    }
    shell.cssOverview.pick = .color(color.label)
    let filtered = summary.sheets(matching: .color(color.label))
    guard !filtered.isEmpty, filtered.allSatisfy({ $0.contains("shaar-css-overview.css") }) else {
      throw Failure("Selecting #5b21b6 did not filter sheets. \(filtered)")
    }
    return
      "CSS overview counted \(color.label) \(color.count) times across \(summary.examined) sheets and left the empty sheet out of that color."
  }

  private func cssOverviewMatches(_ summary: ShaarDevToolsCSSSummary) -> Bool {
    guard summary.examined >= 2,
      let color = summary.colors.first(where: { $0.label.lowercased().contains("5b21b6") }),
      color.count >= 2
    else { return false }
    let rgb = summary.colors.contains { normalizedColor($0.label) == "rgb(91,33,182)" }
    let font = summary.fonts.contains { $0.label == "Shaar Overview" }
    let media = summary.media.contains { $0.label.contains("min-width: 840px") }
    return rgb && font && media
  }

  private func normalizedColor(_ label: String) -> String {
    label.lowercased().filter { !$0.isWhitespace }
  }

  private func cssDiagnostic(_ shell: ShaarDevToolsModel) async -> String {
    let summary = shell.cssOverview.summary
    let colors = summary.colors.prefix(8).map { "\($0.label)x\($0.count)" }.joined(separator: ", ")
    let fonts = summary.fonts.prefix(8).map(\.label).joined(separator: ", ")
    let media = summary.media.prefix(4).map(\.label).joined(separator: ", ")
    let sheets = summary.contributingSheets.prefix(8).joined(separator: ", ")
    var tree = ""
    if let reply = try? await shell.phase2.execute(.resourceTree) {
      tree = reply.items.prefix(12).map { item in
        let type = item.text["type"] ?? ""
        let mime = item.text["mimeType"] ?? ""
        let url = item.text["url"] ?? ""
        return "\(type) \(mime) \(url)"
      }.joined(separator: " | ")
    }
    return
      "examined=\(summary.examined) colors=[\(colors)] fonts=[\(fonts)] media=[\(media)] sheets=[\(sheets)] failure=\(shell.cssOverview.failure ?? "") tree=[\(tree)]"
  }

  private func proveAudits(
    shell: ShaarDevToolsModel, inspector: InspectorModel
  ) async throws -> String {
    let previous = shell.section
    defer { shell.section = previous }
    shell.section = .audits
    let planted = try await inspector.evaluate(Self.auditPlant)
    guard planted as? Bool == true else {
      throw Failure("Audit fixture controls were not added to the page")
    }
    do {
      let summary = try await proveAuditResults(shell: shell, inspector: inspector)
      _ = try? await inspector.evaluate(Self.auditClear)
      return summary
    } catch {
      _ = try? await inspector.evaluate(Self.auditClear)
      throw error
    }
  }

  private func proveAuditResults(
    shell: ShaarDevToolsModel, inspector: InspectorModel
  ) async throws -> String {
    let route = shell.target.url.path.isEmpty ? "/" : shell.target.url.path
    let project = try auditBudgetProject(route: route)
    defer { try? FileManager.default.removeItem(at: project) }
    try shell.performance.loadBudgets(from: project)
    guard inspector.isOpen, shell.pageAudit.inspector != nil else {
      throw Failure("Audits has no Inspector for this tab")
    }
    shell.pageAudit.setScope(.page)
    shell.pageAudit.run()
    try await wait("axe report", attempts: 200) {
      !shell.pageAudit.busy && (shell.pageAudit.report != nil || shell.pageAudit.failure != nil)
    }
    guard let report = shell.pageAudit.report else {
      throw Failure("Audit did not finish: \(shell.pageAudit.failure ?? "no report")")
    }
    let rules = Set(report.findings.map(\.ruleID))
    guard rules.contains("button-name"), rules.contains("image-alt") else {
      let listed = rules.sorted().joined(separator: ", ")
      throw Failure("Audit missed the planted controls. rules=[\(listed)]")
    }
    if shell.phase2.available { await shell.performance.refresh() }
    let counts = shell.auditCounts
    guard counts.hasReport, counts.violations >= 2, counts.hasBudget,
      shell.auditRoute == route,
      counts.passed + counts.over + counts.unavailable == 2,
      counts.passed + counts.over >= 1
    else {
      let metrics =
        shell.performance.budgetResult?.metrics.map {
          "\($0.name)=\($0.status.rawValue)"
        }.joined(separator: ", ") ?? "none"
      throw Failure(
        "Audit counts route=\(shell.auditRoute ?? "nil") violations=\(counts.violations) passed=\(counts.passed) over=\(counts.over) unavailable=\(counts.unavailable) metrics=[\(metrics)]"
      )
    }
    return
      "axe reported \(counts.violations) violations, including the unnamed button and the image without alt. Route budget \(route) passed \(counts.passed), over \(counts.over), unavailable \(counts.unavailable)."
  }

  private func auditBudgetProject(route: String) throws -> URL {
    let project = FileManager.default.temporaryDirectory.appending(
      path: "shaar-audit-budget-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = project.appending(path: ".shaar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payload = """
      {"schemaVersion":1,"routes":[{"route":"\(route)","cls":1,"requestCount":1000000}]}
      """
    try Data(payload.utf8).write(to: directory.appending(path: "budgets.json"))
    return project
  }

  private static let auditPlant = """
    (() => {
      const button = document.createElement('button');
      button.id = 'shaar-audit-unnamed';
      const image = document.createElement('img');
      image.id = 'shaar-audit-image';
      image.src = '/favicon-initial.png';
      document.body.append(button, image);
      return true;
    })()
    """

  private static let auditClear = """
    (() => {
      document.getElementById('shaar-audit-unnamed')?.remove();
      document.getElementById('shaar-audit-image')?.remove();
      return true;
    })()
    """

  private func engineLevel(_ shell: ShaarDevToolsModel) -> String? {
    let info = engine.runtime.securityInfo(
      forTabID: shell.target.tabID.uuidString, profileID: shell.target.profileID.uuidString)
    return info?["level"] as? String
  }

  private func connectionName(_ connection: ShaarPageConnection) -> String {
    switch connection {
    case .secure: "secure"
    case .http: "http"
    case .certificateError: "certificateError"
    case .mixedContent: "mixedContent"
    case .unavailable: "unavailable"
    }
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

  private func proveIssues(shell: ShaarDevToolsModel, inspector: InspectorModel) async throws
    -> String
  {
    let previous = shell.section
    defer { shell.section = previous }
    _ = try await inspector.evaluate(
      "console.error('shaar-issue-copy'); console.error('shaar-issue-copy'); fetch('/shaar-issues-missing',{cache:'no-store'}); true"
    )
    do {
      try await wait("grouped issue and failed request") { self.issuesReady(shell) }
    } catch {
      throw Failure("Issues not ready: \(self.issueSummary(shell))")
    }
    let rows = shell.issues
    guard
      let consoleIssue = rows.first(where: { $0.title == "shaar-issue-copy" && $0.count >= 2 }),
      case .console(let consoleID, _) = consoleIssue.kind,
      let networkIssue = rows.first(where: { self.isMissingRequest($0) }),
      case .network(let networkID, _, _) = networkIssue.kind
    else { throw Failure("Issue rows disappeared: \(issueSummary(shell))") }
    shell.openIssue(consoleIssue)
    guard shell.section == .console, shell.console.selectedID == consoleID else {
      throw Failure("Choosing a console issue did not open Console")
    }
    shell.openIssue(networkIssue)
    guard shell.section == .network, shell.network.selectedID == networkID else {
      throw Failure("Choosing a network issue did not open Network")
    }
    return
      "Identical console errors counted as 1 issue (\(consoleIssue.count) times). Failed request listed. Choosing a row opened Console, then Network. Tab count \(rows.count)."
  }

  private func issuesReady(_ shell: ShaarDevToolsModel) -> Bool {
    let rows = shell.issues
    let grouped = rows.contains { $0.title == "shaar-issue-copy" && $0.count >= 2 }
    return grouped && rows.contains { self.isMissingRequest($0) }
  }

  private func isMissingRequest(_ issue: ShaarDevToolsIssue) -> Bool {
    guard case .network = issue.kind else { return false }
    return issue.title.contains("shaar-issues-missing")
  }

  private func issueSummary(_ shell: ShaarDevToolsModel) -> String {
    shell.issues
      .map { "\($0.count)x \(String($0.title.prefix(80)))" }
      .joined(separator: " | ")
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
    "Live heap snapshots need engine support",
    "Memory tools are unavailable for this tab",
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

  /// The split-shell check focuses another tab and closes its shell, which
  /// drops the one panel lease. Bring /inspector-tools back and open a new lease.
  private func restoreInspectorToolsLease(
    _ shell: ShaarDevToolsModel, tab: UUID
  ) async throws {
    if engine.siteControlTarget?.tabID != tab {
      store.focusSplitTab(tab)
    }
    try await wait("inspector-tools tab focused") {
      self.engine.siteControlTarget?.tabID == tab
    }
    let path = engine.siteControlTarget?.url.path ?? ""
    guard path == "/inspector-tools" else {
      throw Failure("Performance and Sources need /inspector-tools, found \(path)")
    }
    if !shell.phase2.available {
      shell.updateTarget(shell.target, committed: true)
    }
    do {
      try await wait("phase 2 lease") { shell.phase2.available }
    } catch {
      let failure = shell.nativePhase2Failure ?? shell.nativeStreamFailure ?? "none"
      throw Failure(
        "Phase 2 lease did not return. stream=\(shell.streamAvailable) failure=\(failure)"
      )
    }
  }

  /// The phase-2 vitals expression has no Largest Contentful Paint entry, and its
  /// event buffer ignores the fixture's 80ms click. The page script already
  /// observes both. Read it after long tasks are recorded so a developer-session
  /// failure still leaves that recording in the result.
  private func provePageVitals(
    _ shell: ShaarDevToolsModel, target: SiteControlTarget, tab: UUID,
    inspector: InspectorModel
  ) async -> String {
    do {
      let developer = engine.developerModel(for: target)
      try await wait("developer session idle") { !developer.applying }
      developer.setPerformanceEnabled(true)
      try await wait("developer performance session") { !developer.applying }
      try await developer.refreshPerformance()
      let clicked: Bool = await withCheckedContinuation { continuation in
        self.engine.runtime.clickProbeElement(
          inTabID: tab.uuidString, elementID: "performance-input"
        ) { continuation.resume(returning: $0) }
      }
      try await Task.sleep(for: .milliseconds(100))
      try await developer.refreshPerformance()
      if let snapshot = developer.performanceSnapshot {
        shell.performance.updatePageSnapshot(snapshot)
      }
      var note = clicked ? "" : " click=missed"
      if shell.performance.lcpMilliseconds == nil || shell.performance.inpMilliseconds == nil {
        let state = try await inspector.evaluate("document.visibilityState") as? String
        let snapshotLCP = developer.performanceSnapshot?.lcp.map { String($0) } ?? "nil"
        let snapshotINP = developer.performanceSnapshot?.inp.map { String($0) } ?? "nil"
        note +=
          " visibility=\(state ?? "nil") snapshotLCP=\(snapshotLCP) snapshotINP=\(snapshotINP)"
      }
      return note
    } catch {
      return " vitals=\(error.localizedDescription)"
    }
  }

  private func refreshPerformance(_ model: ShaarPerformanceModel) async throws {
    var attempts = 0
    while attempts < 5 {
      try await wait("performance idle") { !model.loading }
      let before = model.completedRefreshes
      await model.refresh()
      if model.completedRefreshes > before {
        if let failure = model.failure {
          throw Failure("Performance refresh failed: \(failure)")
        }
        return
      }
      attempts += 1
      try await Task.sleep(for: .milliseconds(20))
    }
    throw Failure("Performance refresh did not run")
  }

  private func check(_ name: String, _ operation: () async throws -> String) async {
    await results.check(name, operation)
  }

  /// The first child list can miss a node inserted afterwards. Ask the page again.
  private func reloadBodyChildren(_ dom: ShaarDOMTreeModel) async throws {
    await dom.loadDocument()
    try await wait("DOM reload before copy host") {
      dom.rootID != nil && !dom.loading && dom.nodes.values.contains { $0.name == "BODY" }
    }
    guard let body = dom.nodes.values.first(where: { $0.name == "BODY" }) else {
      throw Failure("BODY missing after reload")
    }
    if dom.expanded.contains(body.id) {
      await dom.toggleExpanded(body.id)
    }
    await dom.toggleExpanded(body.id)
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
    "f12-route", "shell-defaults", "security", "audits", "console-network", "network-tools",
    "network-throttle", "network-row", "console-repeat", "issues", "application-cookie",
    "application-local-storage", "application-session-storage", "application-indexed-db",
    "application-cache-storage", "application-service-worker", "network-rules", "source-bytes",
    "css", "viewports", "masked-repro", "elements-live", "elements-inspector", "elements-scale",
    "split-shell", "console-tools", "memory", "performance-recording", "sources-lite",
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
