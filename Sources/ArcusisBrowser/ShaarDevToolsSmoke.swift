// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import ObjectiveC.runtime
import Vision

/// Walks Shaar DevTools in the shipping app. Windows stay unordered and offscreen.
@MainActor enum ShaarDevToolsSmoke {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.host == "127.0.0.1", pageURL.scheme == "http" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let keys = ShaarDevToolsSmokeKeys()
    do {
      let guardWindow = try ShaarDevToolsSmokeWindowGuard.install()
      defer { guardWindow.restore() }
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe,
        keyWindow: { keys.window })
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await exercise(host: host, pageURL: pageURL, outputURL: outputURL, keys: keys)
        }
      }
      return withExtendedLifetime(host) {
        // An unordered window is occluded. Production leaves that renderer frozen;
        // the probe switches are what let a hidden page load and paint.
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, pageURL: URL, outputURL: URL, keys: ShaarDevToolsSmokeKeys
  ) async {
    let report = ShaarDevToolsSmokeReport(directory: outputURL.deletingLastPathComponent())
    report.note(
      "probe-switches",
      "Hidden-window probe switches are on so an occluded window still loads")
    defer {
      report.finish(hidden: windowsHidden(host))
      write(report.payload, to: outputURL)
      host.events.quit()
    }
    do { try host.restore() } catch {
      report.fail("restore", error.localizedDescription)
      return
    }
    guard let context = host.contexts.values.first else {
      report.fail("restore", "No hidden browser context")
      return
    }
    keys.window = context.window
    widen(context)
    context.store.perform(.open(pageURL))
    let opened = await wait(attempts: 900) {
      pageReady(context, pageURL)
    }
    guard opened, let target = context.engine.siteControlTarget else {
      report.fail("page", pageDiagnostic(context, pageURL))
      return
    }
    report.pass("page", target.url.absoluteString)
    guard await openWithF12(context: context, report: report) else { return }
    guard let shell = context.engine.shaarDevTools[target.tabID],
      let inspector = context.engine.inspectors[target.tabID]
    else {
      report.fail("f12", "Shaar DevTools shell was missing after F12")
      return
    }
    let streamed = await wait(attempts: 100) {
      shell.streamAvailable || shell.nativeStreamFailure != nil
    }
    if streamed && shell.streamAvailable {
      report.pass("stream", "Live DevTools stream is connected")
    } else {
      report.fail("stream", shell.nativeStreamFailure ?? "Live DevTools stream did not connect")
    }
    _ = await wait(attempts: 80) { shell.phase2.available || shell.nativePhase2Failure != nil }
    if shell.phase2.available {
      report.pass("phase2", "Application, Performance, and Sources can use the live lease")
    } else {
      report.fail("phase2", shell.nativePhase2Failure ?? "Phase 2 lease did not connect")
    }
    if context.store.reloadCurrentPage() {
      let reloaded = await wait(attempts: 80) { pageReady(context, pageURL) }
      if !reloaded {
        report.fail("fixture", "Reload before the panel walk did not commit")
      }
    } else {
      report.fail("fixture", "Reload before the panel walk was refused")
    }
    if await fixtureReady(inspector) {
      report.pass("fixture", "Storage, network, and the service worker finished")
    } else {
      report.fail("fixture", "The page did not finish its storage setup")
    }
    prepareDock(shell, context: context)
    await settle(context)
    await walkPanels(shell: shell, context: context, report: report)
    await exerciseActions(
      shell: shell, inspector: inspector, context: context, host: host, pageURL: pageURL,
      report: report)
    if !windowsHidden(host) {
      report.fail("windows", "A window became visible")
    } else {
      report.pass("windows", "Every window stayed hidden")
    }
    if shell.isOpen {
      report.pass("quit-open", "DevTools is still open when the app quits")
    } else {
      report.fail("quit-open", "DevTools closed before quit")
    }
  }

  private static func openWithF12(
    context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async -> Bool {
    guard postedF12(context) else {
      report.fail("f12", "Could not build the F12 event")
      return false
    }
    let opened = await wait(attempts: 30) {
      guard let tab = context.engine.siteControlTarget?.tabID else { return false }
      return context.engine.shaarDevTools[tab]?.isOpen == true
    }
    if opened {
      report.pass("f12", "F12 opened Shaar DevTools")
      return true
    }
    report.fail("f12", "F12 did not open Shaar DevTools")
    context.engine.toggleDeveloperTools()
    return await wait(attempts: 20) {
      guard let tab = context.engine.siteControlTarget?.tabID else { return false }
      return context.engine.shaarDevTools[tab]?.isOpen == true
    }
  }

  private static func walkPanels(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    report.note(
      "painted-text",
      "A hidden window does not expose SwiftUI controls in the accessibility tree. The smoke reads the offscreen bitmap, and runs the button action when the press does not land.")
    for section in shell.sections {
      let button = "shaar.devtools.\(section.rawValue.lowercased())"
      let started = Date()
      let pressed = ShaarDevToolsSmokeAccess.press(identifier: button, in: context.hosting)
      if !pressed || shell.section != section {
        shell.section = section
      }
      let content = contentIdentifier(section)
      if let content {
        let appeared = await wait(attempts: 25) {
          ShaarDevToolsSmokeAccess.element(identifier: content, in: context.hosting) != nil
        }
        let elapsed = Date().timeIntervalSince(started)
        if appeared, elapsed > 2 {
          report.fail(
            "look/slow/\(section.rawValue)",
            String(format: "First content took %.1f seconds", elapsed),
            severity: .polish)
        }
      }
      await settle(context)
      let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
      recordTab(section, pressed: pressed && shell.section == section, painted: painted, report: report)
      recordSidebarTitle(painted, report: report)
      await provePanel(section, shell: shell, context: context, painted: painted, report: report)
      ShaarDevToolsSmokeLook.survey(
        panel: section.rawValue, contentIdentifier: content, in: context.hosting,
        failure: panelFailure(section, shell: shell), report: report)
      ShaarDevToolsSmokeLook.focus(panel: section.rawValue, in: context.hosting, report: report)
      let name = section.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()
      let url = report.directory.appending(path: "panel-\(name).png")
      if ShaarDevToolsSmokeAccess.capture(context.hosting, to: url) {
        report.note("capture-\(section.rawValue)", url.lastPathComponent)
      } else {
        report.fail("capture-\(section.rawValue)", "Offscreen capture failed")
      }
    }
    if !report.contains("look/clip/sidebar") {
      report.fail(
        "look/clip/sidebar",
        "The sidebar tab title was not readable.",
        severity: .polish)
    }
    await proveIssueBadge(shell, context: context, report: report)
  }

  private static func recordSidebarTitle(
    _ painted: String, report: ShaarDevToolsSmokeReport
  ) {
    guard !report.contains("look/clip/sidebar") else { return }
    if SidebarTabTitle.isMidwordClip(painted) {
      report.fail(
        "look/clip/sidebar",
        "The sidebar tab title is cut off (“Shaar DevToo…”).",
        severity: .polish)
      return
    }
    if SidebarTabTitle.showsFullTitle(painted) {
      report.pass("look/clip/sidebar", "The sidebar tab shows the page title")
    }
  }

  private static func recordTab(
    _ section: ShaarDevToolsSection, pressed: Bool, painted: String,
    report: ShaarDevToolsSmokeReport
  ) {
    let label = toolbarLabel(section)
    if pressed {
      report.pass("tab-\(section.rawValue)", "The \(label) tab selected the panel")
      return
    }
    if painted.isEmpty {
      report.pass("tab-\(section.rawValue)", "Selected \(label). The bitmap had no readable text.")
      return
    }
    if ShaarDevToolsSmokeAccess.shows(label, in: painted) || panelIsPainted(section, in: painted) {
      report.pass("tab-\(section.rawValue)", "The \(label) tab is on screen")
      return
    }
    report.fail(
      "tab-\(section.rawValue)", "The \(label) tab was not in the toolbar", severity: .polish)
  }

  private static func proveIssueBadge(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let count = shell.issues.count
    guard count > 0 else { return }
    shell.section = .issues
    await settle(context)
    let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
    if ShaarDevToolsSmokeAccess.shows("No issues", in: painted) {
      report.fail(
        "issues-badge",
        "The Issues tab counts \(count), and the panel says there are no issues.",
        severity: .wrong)
    } else {
      report.pass("issues-badge", "Issues lists \(count)")
    }
  }

  private static func provePanel(
    _ section: ShaarDevToolsSection, shell: ShaarDevToolsModel, context: NativeBrowserContext,
    painted: String, report: ShaarDevToolsSmokeReport
  ) async {
    let name = "panel-\(section.rawValue)"
    switch section {
    case .coverage:
      await settle(context)
      let sentence = "Coverage collection waits for the next engine build."
      let showing = showsBanner(sentence, painted: painted, in: context.hosting)
      if shell.coverage.collectionReady, !showing {
        report.pass(name, "Start is enabled and the next-engine sentence is gone")
      } else {
        report.fail(
          name,
          "Start is disabled. The panel says “\(sentence)”")
      }
    case .sensors:
      _ = await wait(attempts: 40) { shell.idleProbeFinished }
      await settle(context)
      let touchSentence = "Touch emulation waits for the next engine build."
      let touchShowing = showsBanner(touchSentence, painted: painted, in: context.hosting)
      let idleBanner = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.sensorIdleNote", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("Idle emulation waits", in: painted)
      if shell.sensorTouchReady, shell.sensorIdleReady, !touchShowing, !idleBanner {
        report.pass(name, "Touch and idle are enabled")
      } else if !shell.sensorTouchReady || touchShowing {
        report.fail(name, "Touch is disabled. The panel says “\(touchSentence)”")
      } else {
        report.fail(name, "Idle is disabled and still shows a next-engine note")
      }
    case .rendering:
      _ = await wait(attempts: 80) { shell.rendering.overlayProbeFinished }
      await settle(context)
      let note = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.rendering.overlayNote", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("Paint flashing waits", in: painted)
      if shell.rendering.overlayCommandsAvailable, !note {
        report.pass(name, "Paint flashing is available")
      } else {
        report.fail(name, shell.rendering.failure ?? "Rendering overlay still waits for an engine build")
      }
    case .memory:
      let gate = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.memory.engineGate", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("Live heap snapshots need engine support", in: painted)
      if gate {
        report.fail(name, "Memory shows a needs-engine banner on shaar.21")
      } else if panelIsPainted(section, in: painted) {
        report.pass(name, "Memory does not show a needs-engine banner before the snapshot")
      } else {
        report.fail(name, "Memory panel did not render")
      }
    case .audits:
      let panel = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.audits", in: context.hosting)
      let run = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.runAudit", in: context.hosting)
      if (panel != nil && run != nil) || panelIsPainted(section, in: painted) {
        report.pass(name, "Audits rendered. Run audit was not pressed.")
      } else {
        report.fail(name, "Audits panel did not render")
      }
    case .elements:
      await proveElements(name, shell: shell, context: context, painted: painted, report: report)
    case .issues:
      if panelIsPainted(section, in: painted) || !shell.issues.isEmpty {
        report.pass(name, "Issues")
      } else {
        provePainted(
          name, section: section, root: panelRoot(section), painted: painted, in: context,
          report: report)
      }
    case .network:
      provePainted(name, section: section, root: panelRoot(section), painted: painted, in: context, report: report)
      if shell.network.requests(from: shell.events).isEmpty {
        report.fail(
          "network-stale",
          "Network says there are no requests after the fixture loaded /qa, /api/items, and /api/xhr.",
          severity: .wrong)
      }
    default:
      provePainted(name, section: section, root: panelRoot(section), painted: painted, in: context, report: report)
    }
  }

  private static func showsBanner(_ sentence: String, painted: String, in root: NSView) -> Bool {
    if ShaarDevToolsSmokeAccess.shows(sentence, in: painted) { return true }
    return ShaarDevToolsSmokeAccess.element(label: sentence, in: root) != nil
  }

  private static func provePainted(
    _ name: String, section: ShaarDevToolsSection, root: String?, painted: String,
    in context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) {
    let found = root.map {
      ShaarDevToolsSmokeAccess.element(identifier: $0, in: context.hosting) != nil
    } ?? false
    let blocked = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.streamUnavailable", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("needs engine support", in: painted)
    if blocked {
      report.fail(name, "Shows the unavailable banner")
      return
    }
    if found || panelIsPainted(section, in: painted) {
      report.pass(name, root ?? toolbarLabel(section))
      return
    }
    if painted.isEmpty {
      report.fail(name, "The panel could not be read from the bitmap or the accessibility tree")
      return
    }
    report.fail(name, "Panel root did not render")
  }

  private static func exerciseActions(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    host: NativeBrowserHost, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    await coverageRoundTrip(shell, context: context, report: report)
    await touchRoundTrip(shell, context: context, report: report)
    await memorySnapshot(shell, context: context, report: report)
    await consoleEvaluate(shell, inspector: inspector, context: context, report: report)
    await consoleFilters(shell, context: context, report: report)
    await networkActions(shell, inspector: inspector, context: context, report: report)
    await applicationStorage(shell, context: context, report: report)
    await performanceRecord(shell, context: context, report: report)
    await recorderRoundTrip(shell, context: context, report: report)
    await renderingPaint(shell, context: context, report: report)
    await cssReload(shell, context: context, report: report)
    await chromeActions(
      shell: shell, context: context, host: host, pageURL: pageURL, report: report)
  }

  private static func coverageRoundTrip(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .coverage
    await settle(context)
    guard shell.coverage.collectionReady else {
      report.fail("coverage-record", "Start stayed disabled")
      return
    }
    _ = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.coverageStart", in: context.hosting)
    let started = await wait(attempts: 40) {
      shell.coverage.recording || shell.coverage.notice != nil
    }
    guard started, shell.coverage.recording else {
      report.fail("coverage-record", shell.coverage.notice.map(String.init(describing:)) ?? "Start did nothing")
      return
    }
    _ = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.coverageStop", in: context.hosting)
    let stopped = await wait(attempts: 40) { !shell.coverage.recording }
    if stopped, shell.coverage.notice == nil {
      report.pass("coverage-record", "Start and Stop ran. Rows \(shell.coverage.rows.count)")
    } else {
      report.fail(
        "coverage-record",
        shell.coverage.notice.map(String.init(describing:)) ?? "Stop did not finish")
    }
  }

  private static func touchRoundTrip(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .sensors
    await settle(context)
    guard shell.sensorTouchReady else {
      report.fail("touch", "Touch switch stayed disabled")
      return
    }
    _ = ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.sensorTouch", in: context.hosting)
    await settle(context)
    if shell.sensorTouch {
      report.pass("touch", "Touch switch sent the emulation")
    } else {
      report.fail("touch", "Pressing Touch did not turn emulation on")
    }
  }

  private static func memorySnapshot(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .memory
    await settle(context)
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.memory.snapshot", in: context.hosting)
    if !pressed { await shell.memory.takeSnapshot() }
    let finished = await wait(attempts: 150) {
      shell.memory.snapshot != nil || shell.memory.failure != nil || shell.memory.support == .needsEngine
    }
    let gate = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.memory.engineGate", in: context.hosting)
    if finished, shell.memory.snapshot != nil, gate == nil, shell.memory.support == .ready {
      report.pass("memory-snapshot", "Heap snapshot completed")
    } else {
      report.fail("memory-snapshot", shell.memory.failure ?? "Heap snapshot did not finish")
    }
  }

  private static func consoleEvaluate(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .console
    await settle(context)
    shell.console.command = "6*7"
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
    _ = await wait(attempts: 30) {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("42")
      }
    }
    let rows = shell.console.rows(from: shell.consoleEvents)
    if rows.contains(where: { $0.event.message.contains("42") }) {
      report.pass("console", "The command line evaluated 6*7")
    } else if rows.contains(where: { $0.event.message.contains("> 6*7") }) {
      report.fail("console", "Command ran but the result was not 42", severity: .wrong)
    } else {
      report.fail("console", "6*7 did not appear in the console")
    }
  }

  private static func networkActions(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .network
    await settle(context)
    _ = try? await inspector.evaluate(
      "fetch('/api/items', {cache:'no-store'}).then(function(response){return response.text()})")
    let row = await wait(attempts: 50) {
      !shell.network.requests(from: shell.events).isEmpty
    }
    if row {
      let count = shell.network.requests(from: shell.events).count
      report.pass("network-rows", "\(count) requests")
    } else {
      report.fail("network-rows", "No network rows")
      ShaarDevToolsSmokeLook.recordBlank(panel: "Network", in: context.hosting, report: report)
    }
    let pressedRow = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.networkRequest", in: context.hosting)
    if !pressedRow, shell.network.selectedID == nil {
      shell.network.selectedID = shell.network.requests(from: shell.events).first?.id
    }
    let pressedCache = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.networkCache", in: context.hosting)
    if !pressedCache { await shell.network.conditions.setCacheDisabled(true) }
    let cache = await wait(attempts: 30) {
      shell.network.conditions.cacheDisabled || shell.network.conditions.failure != nil
    }
    if cache, shell.network.conditions.cacheDisabled, shell.network.conditions.failure == nil {
      report.pass("network-cache", "Disable cache is on")
    } else {
      report.fail("network-cache", shell.network.conditions.failure ?? "Disable cache did not stick")
    }
    await shell.network.conditions.select(.fast3G)
    if shell.network.conditions.throttle == .fast3G, shell.network.conditions.failure == nil {
      await shell.network.conditions.select(.none)
      report.pass("network-throttle", "Fast 3G applied and cleared")
    } else {
      report.fail("network-throttle", shell.network.conditions.failure ?? "Throttle did not apply")
    }
    let harPainted = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.networkHAR", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows(
        "Export HAR", in: ShaarDevToolsSmokeAccess.renderedText(context.hosting))
    let har = ShaarNetworkHAR.document(requests: shell.network.exportRequests(from: shell.events))
    if harPainted, !har.isEmpty {
      report.pass("network-har", "Export HAR is in the toolbar and the document has \(har.count) bytes. The save panel was not opened.")
    } else if har.isEmpty {
      report.fail("network-har", "Export HAR had nothing to write", severity: .wrong)
    } else {
      report.fail("network-har", "Export HAR was missing")
    }
    let pressedRules = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.networkRules", in: context.hosting)
    if !pressedRules { shell.rules.showingRules = true }
    await settle(context)
    let rulesPainted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
    let rulesMissing = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.networkRulesUnavailable", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("Network rules need engine support", in: rulesPainted)
    let rulesOpen = shell.rules.showingRules
      && (ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.networkRulesEditor", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("No saved rules", in: rulesPainted)
        || ShaarDevToolsSmokeAccess.shows("Network rules", in: rulesPainted))
    if rulesOpen, !rulesMissing {
      report.pass("network-rules", "Rules editor opened")
    } else if rulesMissing {
      report.fail("network-rules", "Network rules still show the needs-engine state")
    } else {
      report.fail("network-rules", "Rules editor did not open")
    }
    if let selected = shell.network.selectedID,
      let request = shell.network.requests(from: shell.events).first(where: { $0.id == selected })
    {
      let curl = shell.network.curlCommand(for: request)
      if curl.contains("curl") {
        report.pass("network-curl", "Copy as cURL built a curl command")
      } else {
        report.fail("network-curl", "Copy as cURL was malformed: \(curl.prefix(80))", severity: .wrong)
      }
    } else {
      report.fail("network-curl", "No selected request to copy")
    }
  }

  private static func chromeActions(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, host: NativeBrowserHost,
    pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    let pressedMenu = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.commandMenuButton", in: context.hosting)
    if !pressedMenu { shell.toggleCommandMenu() }
    await settle(context)
    if shell.commandMenuOpen {
      shell.closeCommandMenu()
      report.pass("command-menu", "Command-menu button opened the menu")
    } else {
      report.fail("command-menu", "Command menu did not open")
    }
    shell.showSettings()
    await settle(context)
    if shell.settingsOpen {
      shell.closeSettings()
      report.pass("settings", "Settings opened over DevTools")
    } else {
      report.fail("settings", "Settings did not open")
    }
    let before = shell.rightWidth
    shell.dock = .right
    shell.rightWidth = ShaarDevToolsSizing.side(before + 80, available: context.hosting.bounds.width)
    await settle(context)
    let handle = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.resize", in: context.hosting)
    if handle != nil, shell.rightWidth > before {
      report.pass("resize", "Split handle is present and the side width grew")
    } else if shell.rightWidth > before {
      report.pass(
        "resize",
        "The side width grew. The split handle is not exposed on the hidden accessibility tree, so the drag was not performed.")
    } else {
      report.fail("resize", "The side width did not change")
    }
    shell.dock = .bottom
    await settle(context)
    if shell.dock == .bottom {
      report.pass("dock-bottom", "Docked to the bottom")
    } else {
      report.fail("dock-bottom", shell.dock.rawValue)
    }
    shell.dock = .left
    await settle(context)
    if shell.dock == .left, windowsHidden(host) {
      report.pass("dock-left", "Docked to the left")
    } else {
      report.fail("dock-left", shell.dock.rawValue)
    }
    shell.dock = .floating
    await settle(context)
    if shell.dock == .floating, windowsHidden(host) {
      report.pass("dock-floating", "Pop-out stayed offscreen")
    } else {
      report.fail("dock-floating", "Pop-out ordered a window onscreen")
    }
    shell.dock = .right
    shell.close()
    await settle(context)
    if shell.isOpen {
      report.fail("close", "Close left DevTools open")
    } else if postedF12(context) {
      let reopened = await wait(attempts: 30, until: { shell.isOpen })
      if reopened {
        report.pass("reopen", "Close and a second F12 reopened DevTools")
      } else {
        report.fail("reopen", "The second F12 did not reopen DevTools")
      }
    } else {
      report.fail("reopen", "The second F12 could not be posted")
    }
    if context.store.reloadCurrentPage() {
      let reloaded = await wait(attempts: 80) { pageReady(context, pageURL) }
      if reloaded {
        report.pass("reload", "Reload committed the same page")
      } else {
        report.fail("reload", "Reload did not commit")
      }
    } else {
      report.fail("reload", "Reload was refused")
    }
    let away = pageURL.deletingLastPathComponent().appending(path: "away")
    context.store.perform(.open(away))
    let left = await wait(attempts: 80) { pageReady(context, away) }
    context.store.perform(.open(pageURL))
    let back = await wait(attempts: 80) { pageReady(context, pageURL) }
    if left && back {
      report.pass("navigate", "Navigated away and back")
    } else {
      report.fail("navigate", "away=\(left) back=\(back)")
    }
  }

  private static func proveElements(
    _ name: String, shell: ShaarDevToolsModel, context: NativeBrowserContext,
    painted: String, report: ShaarDevToolsSmokeReport
  ) async {
    let ready = await wait(attempts: 80) {
      shell.dom.rootID != nil || shell.dom.failure != nil
        || ShaarDevToolsSmokeAccess.element(identifier: "shaar.devtools.domRow", in: context.hosting)
          != nil
        || ShaarDevToolsSmokeAccess.element(
          identifier: "shaar.devtools.domUnavailable", in: context.hosting) != nil
    }
    let unavailable = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.domUnavailable", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("DOM tree needs engine support", in: painted)
    let blocked = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.streamUnavailable", in: context.hosting) != nil
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.domRow", in: context.hosting)
    if shell.dom.selectedID == nil, let row = shell.dom.rows.first {
      shell.dom.select(row.id)
    }
    if ready, unavailable == false, blocked == false, shell.dom.rootID != nil {
      let how = pressed ? "A DOM row was pressed" : "The DOM tree is on screen"
      report.pass(name, how)
    } else {
      report.fail(name, shell.dom.failure ?? "Elements did not show the DOM tree")
    }
    let listeners = ShaarDevToolsSmokeAccess.element(
      identifier: "shaar.devtools.eventListeners", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("Event listeners", in: painted)
    if listeners {
      report.pass("elements-listeners", "Event listeners pane is in Elements")
    } else {
      report.fail("elements-listeners", "Event listeners pane did not render")
    }
    shell.dom.search = "QA row"
    _ = ShaarDevToolsSmokeAccess.press(label: "Find in DOM", in: context.hosting)
    await shell.dom.performSearch()
    let matched = await wait(attempts: 40) {
      shell.dom.matchCountLabel != nil || shell.dom.failure != nil
    }
    if matched, shell.dom.failure == nil, shell.dom.matchCountLabel != nil {
      report.pass("elements-search", shell.dom.matchCountLabel ?? "Matched")
    } else if let failure = shell.dom.failure {
      report.fail("elements-search", failure)
    } else {
      report.fail("elements-search", "DOM search did not match QA row", severity: .wrong)
    }
  }

  private static func fixtureReady(_ inspector: InspectorModel) async -> Bool {
    for _ in 0..<80 {
      if let ready = try? await inspector.evaluate("window.__qaReady === true"),
        ready as? Bool == true
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private static func consoleFilters(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .console
    await settle(context)
    let sawError = await wait(attempts: 40) {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("qa-error")
      }
    }
    let pressed = ShaarDevToolsSmokeAccess.press(label: "Errors", in: context.hosting)
    if !pressed || shell.console.level != .error { shell.console.level = .error }
    await settle(context)
    let hidden = !shell.console.rows(from: shell.consoleEvents).contains {
      $0.event.message.contains("42")
    }
    if shell.console.level == .error, hidden {
      report.pass("console-filter", "Errors hid the 6*7 result")
    } else if shell.console.level == .error {
      report.fail("console-filter", "Errors still shows the 6*7 result", severity: .wrong)
    } else {
      report.fail("console-filter", "The Errors filter did not apply")
    }
    let pressedAll = ShaarDevToolsSmokeAccess.press(label: "All", in: context.hosting)
    if !pressedAll { shell.console.level = nil }
    await settle(context)
    if shell.console.level == nil {
      report.pass("console-filter-all", "All shows every console level")
    } else {
      report.fail("console-filter-all", "All did not clear the level filter")
    }
    _ = ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.consoleEntry", in: context.hosting)
    await settle(context)
    let consoleRows = shell.console.rows(from: shell.consoleEvents)
    let sawPageLog = consoleRows.contains { $0.event.message.contains("qa-log") }
    let sawPageError = sawError || consoleRows.contains { $0.event.message.contains("qa-error") }
    let stacked = consoleRows.contains {
      $0.event.message.contains("qa-error") && !$0.event.stack.isEmpty
    }
    if stacked {
      report.pass("console-stack", "The page error has a stack")
    } else if sawPageError {
      report.fail("console-stack", "qa-error is present but the stack is empty", severity: .wrong)
    } else if sawPageLog {
      report.fail("console-stack", "qa-log appeared and qa-error did not", severity: .wrong)
    } else {
      report.fail(
        "console-stack",
        "The fixture logged qa-log and qa-error. The console did not show them.")
    }
    let clearedPress = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.consoleClear", in: context.hosting)
    if !clearedPress { shell.console.clearEntries() }
    let cleared = shell.console.rows(from: shell.consoleEvents).contains {
      $0.event.message.contains("qa-error") || $0.event.message.contains("42")
    }
    if !cleared {
      report.pass("console-clear", "Clear removed the page error and the 6*7 result")
    } else {
      report.fail("console-clear", "Clear left stale console rows", severity: .wrong)
    }
  }

  private static func applicationStorage(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .application
    await settle(context)
    await storageArea(
      "Local Storage", area: .local, key: "qa-local", shell: shell, context: context,
      report: report)
    await storageArea(
      "Session Storage", area: .session, key: "qa-session", shell: shell, context: context,
      report: report)
    await storageArea(
      "IndexedDB", area: .indexedDB, key: "qa-db", shell: shell, context: context, report: report)
    await storageArea(
      "Cache Storage", area: .cache, key: "qa-cache", shell: shell, context: context,
      report: report)
    await proveWorkers(shell, context: context, report: report)
    await proveCookies(shell, context: context, report: report)
  }

  private static func storageArea(
    _ label: String, area: ShaarApplicationArea, key: String, shell: ShaarDevToolsModel,
    context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let pressed = ShaarDevToolsSmokeAccess.press(label: label, in: context.hosting)
    if !pressed || shell.application.area != area {
      if pressed {
        report.fail("storage-\(area.rawValue)", "The \(label) button did not select that area")
      }
      shell.application.selectArea(area)
    }
    await shell.application.refresh()
    let found = await wait(attempts: 40) {
      !shell.application.loading
        && (shell.application.failure != nil
          || shell.application.rows.contains { $0.name.contains(key) })
    }
    let listed = shell.application.rows.contains { $0.name.contains(key) }
    if found, shell.application.failure == nil, listed {
      report.pass("storage-\(area.rawValue)", "\(label) lists \(key)")
    } else if let failure = shell.application.failure {
      report.fail("storage-\(area.rawValue)", failure)
    } else if shell.application.loading || !found {
      report.fail("storage-\(area.rawValue)", "\(label) did not finish loading")
    } else if shell.application.rows.isEmpty {
      report.fail("storage-\(area.rawValue)", "\(label) did not list \(key)", severity: .wrong)
      ShaarDevToolsSmokeLook.recordBlank(panel: "Application", in: context.hosting, report: report)
    } else {
      report.fail(
        "storage-\(area.rawValue)", "\(label) loaded but did not list \(key)", severity: .wrong)
    }
  }

  private static func proveWorkers(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let pressed = ShaarDevToolsSmokeAccess.press(label: "Service Workers", in: context.hosting)
    if !pressed || shell.application.area != .workers {
      if pressed {
        report.fail("storage-workers", "The Service Workers button did not select that area")
      }
      shell.application.selectArea(.workers)
    }
    await shell.application.refresh()
    let found = await wait(attempts: 40) {
      !shell.application.loading
        && (shell.application.failure != nil || !shell.application.workers.isEmpty)
    }
    let registered = shell.application.workers.contains { $0.scriptURL.contains("sw.js") }
    if found, shell.application.failure == nil, registered {
      report.pass("storage-workers", "Service worker sw.js is registered")
    } else if let failure = shell.application.failure {
      report.fail("storage-workers", failure)
    } else if shell.application.loading || !found {
      report.fail("storage-workers", "Service workers did not finish loading")
    } else if shell.application.workers.isEmpty {
      report.fail("storage-workers", "No service worker named sw.js", severity: .wrong)
      ShaarDevToolsSmokeLook.recordBlank(panel: "Application", in: context.hosting, report: report)
    } else {
      report.fail(
        "storage-workers", "Service workers loaded but none is sw.js", severity: .wrong)
    }
  }

  private static func proveCookies(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let pressed = ShaarDevToolsSmokeAccess.press(label: "Cookies", in: context.hosting)
    if !pressed || shell.application.area != .cookies {
      if pressed {
        report.fail("storage-cookies", "The Cookies button did not select that area")
      }
      shell.application.selectArea(.cookies)
    }
    await shell.cookies.refresh()
    let found = shell.cookies.cookies.contains { $0.name == "qa-cookie" }
    if shell.cookies.failure == nil, found {
      report.pass("storage-cookies", "qa-cookie is listed")
    } else if let failure = shell.cookies.failure {
      report.fail("storage-cookies", failure)
    } else if shell.cookies.cookies.isEmpty {
      report.fail("storage-cookies", "qa-cookie was missing", severity: .wrong)
      ShaarDevToolsSmokeLook.recordBlank(panel: "Application", in: context.hosting, report: report)
    } else {
      report.fail("storage-cookies", "Cookies loaded but qa-cookie was missing", severity: .wrong)
    }
  }

  private static func performanceRecord(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .performance
    await settle(context)
    let startedPress = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.performanceRecord", in: context.hosting)
    if !startedPress { shell.performance.startRecording() }
    let recording = await wait(attempts: 20) { shell.performance.capture == .recording }
    let stoppedPress = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.performanceRecord", in: context.hosting)
    if !stoppedPress { shell.performance.stopRecording() }
    let idle = await wait(attempts: 20) { shell.performance.capture == .stopped }
    if recording, idle, shell.performance.failure == nil {
      report.pass("performance-record", "Record and Stop ran")
    } else {
      report.fail("performance-record", shell.performance.failure ?? "Record did not start and stop")
    }
  }

  private static func recorderRoundTrip(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .recorder
    await settle(context)
    let pressedRecord = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.recorderRecord", in: context.hosting)
    if !pressedRecord { await shell.recorder.start() }
    let started = await wait(attempts: 40) {
      shell.recorder.recording || shell.recorder.notice != nil
    }
    guard started, shell.recorder.recording else {
      report.fail("recorder", noticeText(shell.recorder.notice) ?? "Record did not start")
      return
    }
    let pressedStop = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.recorderStop", in: context.hosting)
    if !pressedStop { await shell.recorder.stop() }
    let stopped = await wait(attempts: 30) { !shell.recorder.recording }
    if stopped, shell.recorder.notice == nil {
      report.pass("recorder", "Record and Stop ran. Export was not opened.")
    } else {
      report.fail("recorder", noticeText(shell.recorder.notice) ?? "Stop did not finish")
    }
  }

  private static func renderingPaint(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .rendering
    await settle(context)
    guard shell.rendering.overlayCommandsAvailable else {
      report.fail("rendering-paint", shell.rendering.failure ?? "Paint flashing is still disabled")
      return
    }
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.rendering.paintRects", in: context.hosting)
    if !pressed { shell.rendering.paintRects = true }
    await settle(context)
    if shell.rendering.paintRects, shell.rendering.failure == nil {
      report.pass("rendering-paint", "Paint flashing turned on")
    } else {
      report.fail("rendering-paint", shell.rendering.failure ?? "Paint flashing did not turn on")
    }
  }

  private static func cssReload(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .cssOverview
    await settle(context)
    _ = await wait(attempts: 40) { !shell.cssOverview.loading }
    _ = ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.cssReload", in: context.hosting)
    let finished = await wait(attempts: 40) {
      !shell.cssOverview.loading && (shell.cssOverview.loaded || shell.cssOverview.failure != nil)
    }
    if finished, shell.cssOverview.loaded, shell.cssOverview.failure == nil,
      shell.cssOverview.summary.examined > 0
    {
      report.pass("css-overview", "Reload loaded the page style sheets")
    } else if finished, shell.cssOverview.loaded, shell.cssOverview.failure == nil {
      report.fail(
        "css-overview",
        "CSS overview says this page has no style sheets. The fixture page has a style element with color, flex, and grid.",
        severity: .wrong)
    } else {
      report.fail("css-overview", shell.cssOverview.failure ?? "CSS overview did not load")
    }
  }

  private static func postedF12(_ context: NativeBrowserContext) -> Bool {
    guard let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: context.window.windowNumber, context: nil,
      characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 111)
    else { return false }
    NSApp.sendEvent(event)
    return true
  }

  private static func noticeText(_ notice: ShaarRecorderNotice?) -> String? {
    guard let notice else { return nil }
    return String(describing: notice)
  }

  private static func contentIdentifier(_ section: ShaarDevToolsSection) -> String? {
    switch section {
    case .memory: "shaar.devtools.memoryPanel"
    case .coverage: "shaar.devtools.coverage"
    case .audits: "shaar.devtools.audits"
    case .sensors: "shaar.devtools.sensors"
    case .rendering: "shaar.devtools.rendering.panel"
    default: panelRoot(section)
    }
  }

  private static func panelFailure(
    _ section: ShaarDevToolsSection, shell: ShaarDevToolsModel
  ) -> String? {
    switch section {
    case .elements: shell.dom.failure
    case .memory: shell.memory.failure
    case .rendering: shell.rendering.failure
    case .performance: shell.performance.failure
    case .application: shell.application.failure
    case .cssOverview: shell.cssOverview.failure
    case .network: shell.network.conditions.failure
    default: nil
    }
  }

  private static func pageDiagnostic(_ context: NativeBrowserContext, _ pageURL: URL) -> String {
    let target = context.engine.siteControlTarget
    let selected = context.store.session.selectedPage?.tab.url.absoluteString ?? "none"
    let live = context.engine.liveTabs.count
    let loading: String
    if let tab = target?.tabID, let page = context.engine.pages[tab] {
      loading = page.loading ? "true" : "false"
    } else {
      loading = "missing"
    }
    let address = target?.url.absoluteString ?? "none"
    let notice = context.engine.notice ?? ""
    return "No committed web page. target=\(address) selected=\(selected) loading=\(loading) liveTabs=\(live) notice=\(notice) expected=\(pageURL.absoluteString)"
  }

  private static func panelRoot(_ section: ShaarDevToolsSection) -> String? {
    switch section {
    case .elements: "shaar.devtools.domTree"
    case .components: "shaar.devtools.componentTree"
    case .console: "shaar.devtools.consolePanel"
    case .issues: "shaar.devtools.issues"
    case .network: "shaar.devtools.networkPanel"
    case .application: "shaar.devtools.applicationPanel"
    case .performance: "shaar.devtools.performancePanel"
    case .sources: "shaar.devtools.sourcesPanel"
    case .cssOverview: "shaar.devtools.cssOverview"
    case .security: "shaar.devtools.security"
    case .repro: "shaar.devtools.reproPanel"
    case .recorder: "shaar.devtools.recorder"
    case .viewports: "shaar.devtools.viewports.panel"
    case .comparison: "shaar.devtools.comparison.panel"
    case .memory, .coverage, .audits, .sensors, .rendering:
      nil
    }
  }

  private static func prepareDock(_ shell: ShaarDevToolsModel, context: NativeBrowserContext) {
    shell.dock = .bottom
    shell.bottomHeight = min(640, context.hosting.bounds.height * 0.62)
  }

  private static func widen(_ context: NativeBrowserContext) {
    context.window.setFrame(NSRect(x: 0, y: 0, width: 1680, height: 1040), display: false)
    context.hosting.frame = context.contentView.bounds
  }

  private static func settle(_ context: NativeBrowserContext) async {
    context.hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(150))
    context.hosting.layoutSubtreeIfNeeded()
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget else { return false }
    guard target.url.path == pageURL.path else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    host.contexts.values.allSatisfy { !$0.window.isVisible }
      && NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private static func wait(attempts: Int, until ready: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if ready() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return ready()
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private static func toolbarLabel(_ section: ShaarDevToolsSection) -> String {
    switch section {
    case .elements: "Elements"
    case .components: "Comps"
    case .console: "Console"
    case .issues: "Issues"
    case .network: "Network"
    case .application: "App"
    case .performance: "Perf"
    case .memory: "Memory"
    case .coverage: "Coverage"
    case .audits: "Audits"
    case .sources: "Sources"
    case .cssOverview: "CSS"
    case .security: "Security"
    case .sensors: "Sensors"
    case .repro: "Repro"
    case .recorder: "Record"
    case .viewports: "Views"
    case .rendering: "Render"
    case .comparison: "WebKit"
    }
  }

  private static func panelIsPainted(_ section: ShaarDevToolsSection, in text: String) -> Bool {
    panelMarkers(section).contains { ShaarDevToolsSmokeAccess.shows($0, in: text) }
  }

  private static func panelMarkers(_ section: ShaarDevToolsSection) -> [String] {
    switch section {
    case .elements: ["DOM tree", "Event listeners"]
    case .components: ["Component tree", "ReactCounter"]
    case .console: ["No console messages yet", "Evaluate JavaScript", "Search console"]
    case .issues: ["No issues"]
    case .network: ["No network requests yet", "Export HAR", "Disable cache"]
    case .application: ["Filter cookies", "Clear site data", "Local Storage"]
    case .performance: ["Waiting for data", "Main thread"]
    case .memory: ["Heap snapshot", "Take heap snapshot"]
    case .coverage: ["Coverage collection", "No coverage recorded"]
    case .audits: ["Run an audit", "Entire page"]
    case .sources: ["Filter resources", "Find in source"]
    case .cssOverview: ["style sheets", "This page has no style"]
    case .security: ["Not Secure", "loaded over HTTP"]
    case .sensors: ["Touch emulation", "Clear location"]
    case .repro: ["REPRO BUNDLE", "Create .shaarrepro"]
    case .recorder: ["No steps recorded", "Replay"]
    case .viewports: ["Add viewport", "Synced viewports"]
    case .rendering: ["Paint flashing", "Layout shift"]
    case .comparison: ["Refresh comparison", "Webkit-only", "WebKit comparison"]
    }
  }
}

enum ShaarDevToolsSmokeSeverity: String {
  case crash
  case broken
  case wrong
  case polish
  case ok
}

@MainActor final class ShaarDevToolsSmokeReport {
  private(set) var steps: [[String: Any]] = []
  let directory: URL

  init(directory: URL) {
    self.directory = directory
  }

  func pass(_ name: String, _ detail: String) {
    append(name, passed: true, detail, severity: .ok)
  }

  func fail(
    _ name: String, _ detail: String, severity: ShaarDevToolsSmokeSeverity = .broken
  ) {
    append(name, passed: false, detail, severity: severity)
  }

  func note(_ name: String, _ detail: String) {
    append(name, passed: true, detail, severity: .ok)
  }

  func contains(_ name: String) -> Bool {
    steps.contains { ($0["name"] as? String) == name }
  }

  func finish(hidden: Bool) {
    if !hidden { fail("windows-final", "A window was visible at quit") }
  }

  var payload: [String: Any] {
    let passedCount = steps.filter { $0["passed"] as? Bool == true }.count
    let failedCount = steps.count - passedCount
    let passed = failedCount == 0 && !steps.isEmpty
    return [
      "passed": passed,
      "passedCount": passedCount,
      "failedCount": failedCount,
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "steps": steps,
    ]
  }

  private func append(
    _ name: String, passed: Bool, _ detail: String, severity: ShaarDevToolsSmokeSeverity
  ) {
    let place = Self.placement(name)
    steps.append([
      "name": name,
      "panel": place.panel,
      "action": place.action,
      "passed": passed,
      "severity": severity.rawValue,
      "detail": detail,
    ])
  }

  private static func placement(_ name: String) -> (panel: String, action: String) {
    if name == "look/clip/sidebar" { return ("Chrome", "Sidebar tab title") }
    if name.hasPrefix("look/") {
      let parts = name.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        .map(String.init)
      let kind = parts.count > 1 ? parts[1] : "look"
      let panel = parts.count > 2 ? parts[2] : "Other"
      return (panel, lookAction(kind))
    }
    if let panel = prefixed(name, "panel-") { return (panel, "Open panel") }
    if let panel = prefixed(name, "tab-") { return (panel, "Select tab") }
    if let panel = prefixed(name, "capture-") { return (panel, "Offscreen capture") }
    if name == "probe-switches" { return ("Session", "Hidden probe switches") }
    if name == "storage-workers" { return ("Application", "Service workers") }
    if name == "storage-cookies" { return ("Application", "Cookies") }
    if let area = prefixed(name, "storage-") { return ("Application", area) }
    switch name {
    case "page": return ("Session", "Open fixture")
    case "f12": return ("Session", "Press F12")
    case "stream": return ("Session", "Live stream")
    case "phase2": return ("Session", "Phase 2 lease")
    case "fixture": return ("Session", "Fixture ready")
    case "windows", "windows-final": return ("Session", "Windows stay hidden")
    case "quit-open": return ("Session", "Quit with DevTools open")
    case "restore": return ("Session", "Restore hidden window")
    case "coverage-record": return ("Coverage", "Start and stop")
    case "touch": return ("Sensors", "Toggle touch")
    case "memory-snapshot": return ("Memory", "Take heap snapshot")
    case "console": return ("Console", "Evaluate 6*7")
    case "console-filter": return ("Console", "Errors filter")
    case "console-filter-all": return ("Console", "All filter")
    case "console-stack": return ("Console", "Stack trace")
    case "console-clear": return ("Console", "Clear")
    case "network-rows": return ("Network", "Request rows")
    case "network-stale": return ("Network", "Request list")
    case "issues-badge": return ("Issues", "Badge count")
    case "painted-text": return ("Session", "How panels are read")
    case "network-cache": return ("Network", "Disable cache")
    case "network-throttle": return ("Network", "Throttle")
    case "network-har": return ("Network", "HAR document")
    case "network-rules": return ("Network", "Rules editor")
    case "network-curl": return ("Network", "Copy as cURL")
    case "elements-listeners": return ("Elements", "Event listeners")
    case "elements-search": return ("Elements", "Search")
    case "performance-record": return ("Performance", "Record and stop")
    case "recorder": return ("Recorder", "Record and stop")
    case "rendering-paint": return ("Rendering", "Paint flashing")
    case "css-overview": return ("CSS overview", "Reload")
    case "command-menu": return ("Chrome", "Command menu")
    case "settings": return ("Chrome", "Settings")
    case "resize": return ("Chrome", "Resize split")
    case "dock-bottom": return ("Chrome", "Dock bottom")
    case "dock-left": return ("Chrome", "Dock left")
    case "dock-floating": return ("Chrome", "Pop out")
    case "close": return ("Chrome", "Close")
    case "reopen": return ("Chrome", "Reopen with F12")
    case "reload": return ("Session", "Reload")
    case "navigate": return ("Session", "Navigate away and back")
    default: return ("Other", name)
    }
  }

  private static func lookAction(_ kind: String) -> String {
    switch kind {
    case "clip": "Clipping"
    case "text": "Text size"
    case "contrast": "Contrast"
    case "label": "Control label"
    case "spinner": "Spinner"
    case "focus": "Focus"
    case "slow": "Update speed"
    case "blank": "Empty state"
    case "error": "Error state"
    default: kind
    }
  }

  private static func prefixed(_ name: String, _ prefix: String) -> String? {
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
  }
}

enum ShaarDevToolsSmokeAccess {
  @MainActor static func element(identifier: String, in root: NSView) -> NSObject? {
    root.layoutSubtreeIfNeeded()
    return find(identifier: identifier, label: nil, in: root, seen: [])
  }

  @MainActor static func element(label: String, in root: NSView) -> NSObject? {
    root.layoutSubtreeIfNeeded()
    return find(identifier: nil, label: label, in: root, seen: [])
  }

  @MainActor static func press(identifier: String, in root: NSView) -> Bool {
    guard let found = element(identifier: identifier, in: root) else { return false }
    return press(found)
  }

  @MainActor static func press(label: String, in root: NSView) -> Bool {
    root.layoutSubtreeIfNeeded()
    guard let found = find(identifier: nil, label: label, in: root, seen: []) else { return false }
    return press(found)
  }

  @MainActor private static func press(_ object: NSObject) -> Bool {
    if let view = object as? NSView {
      if view.accessibilityPerformPress() { return true }
      return pressHidden(view)
    }
    if let element = object as? NSAccessibilityElement {
      return element.accessibilityPerformPress()
    }
    return false
  }

  @MainActor private static func pressHidden(_ view: NSView) -> Bool {
    guard let window = view.window, !window.isVisible else { return false }
    let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0)
      else { return false }
      if type == .leftMouseDown {
        view.mouseDown(with: event)
      } else {
        view.mouseUp(with: event)
      }
    }
    return true
  }

  @MainActor static func shows(_ needle: String, in text: String) -> Bool {
    let haystack = text.lowercased()
    let token = needle.lowercased()
    guard !token.isEmpty else { return false }
    if token.count >= 5 { return haystack.contains(token) }
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
    return haystack.range(of: pattern, options: .regularExpression) != nil
  }

  @MainActor static func renderedText(_ view: NSView) -> String {
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, view.bounds.height > 1,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return "" }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.cgImage else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return "" }
    return (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }

  @MainActor static func capture(_ view: NSView, to url: URL) -> Bool {
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, view.bounds.height > 1,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  @MainActor private static func find(
    identifier: String?, label: String?, in object: Any, seen: Set<ObjectIdentifier>
  ) -> NSObject? {
    guard let node = object as? NSObject else { return nil }
    let token = ObjectIdentifier(node)
    if seen.contains(token) { return nil }
    var next = seen
    next.insert(token)
    if matches(node, identifier: identifier, label: label) { return node }
    for child in children(of: node) {
      if let found = find(identifier: identifier, label: label, in: child, seen: next) {
        return found
      }
    }
    return nil
  }

  @MainActor private static func matches(_ object: NSObject, identifier: String?, label: String?) -> Bool {
    if let identifier, axIdentifier(object) == identifier { return true }
    if let label, axLabel(object) == label { return true }
    return false
  }

  @MainActor private static func axIdentifier(_ object: NSObject) -> String? {
    if let view = object as? NSView { return view.accessibilityIdentifier() }
    if let element = object as? NSAccessibilityElement { return element.accessibilityIdentifier() }
    return nil
  }

  @MainActor private static func axLabel(_ object: NSObject) -> String? {
    if let view = object as? NSView { return view.accessibilityLabel() }
    if let element = object as? NSAccessibilityElement { return element.accessibilityLabel() }
    return nil
  }

  @MainActor private static func children(of object: NSObject) -> [Any] {
    if let view = object as? NSView {
      var result = view.accessibilityChildren() ?? []
      result.append(contentsOf: view.subviews)
      return result
    }
    if let element = object as? NSAccessibilityElement {
      return element.accessibilityChildren() ?? []
    }
    return []
  }
}

private final class ShaarDevToolsSmokeKeys: @unchecked Sendable {
  nonisolated(unsafe) weak var window: NSWindow?
}

private typealias ShaarDevToolsSmokeWindowOrder = @convention(c) (AnyObject, Selector, Int, Int) -> Void
private nonisolated(unsafe) var shaarDevToolsSmokePreviousOrder: ShaarDevToolsSmokeWindowOrder?

private func shaarDevToolsSmokeOrder(
  _ window: AnyObject, _ selector: Selector, _ place: Int, _ relative: Int
) {
  guard place == NSWindow.OrderingMode.out.rawValue else { return }
  shaarDevToolsSmokePreviousOrder?(window, selector, place, relative)
}

@MainActor final class ShaarDevToolsSmokeWindowGuard {
  private let method: Method
  private let original: IMP
  private var installed = true

  private init(method: Method, original: IMP) {
    self.method = method
    self.original = original
  }

  static func install() throws -> ShaarDevToolsSmokeWindowGuard {
    guard shaarDevToolsSmokePreviousOrder == nil,
      let method = class_getInstanceMethod(
        NSWindow.self, NSSelectorFromString("orderWindow:relativeTo:"))
    else { throw InstallError.unavailable }
    let original = method_getImplementation(method)
    shaarDevToolsSmokePreviousOrder = unsafeBitCast(original, to: ShaarDevToolsSmokeWindowOrder.self)
    let replacement = unsafeBitCast(
      shaarDevToolsSmokeOrder as ShaarDevToolsSmokeWindowOrder, to: IMP.self)
    method_setImplementation(method, replacement)
    return ShaarDevToolsSmokeWindowGuard(method: method, original: original)
  }

  func restore() {
    guard installed else { return }
    method_setImplementation(method, original)
    shaarDevToolsSmokePreviousOrder = nil
    installed = false
  }

  private enum InstallError: Error { case unavailable }
}
