// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation
import ObjectiveC.runtime
import ShaarEngineABI
import Vision

@testable import ArcusisBrowser

/// Walks Shaar DevTools in the verification harness. Windows stay unordered and offscreen.
@MainActor enum ShaarDevToolsSmoke {
  static func run(
    frameworkURL: URL, outputURL: URL, pageURL: URL?, realWorld: Bool = false,
    spaOnly: Bool = false, roundTwo: Bool = false
  ) -> Int32 {
    guard let pageURL,
      realWorld && ["http", "https"].contains(pageURL.scheme ?? "")
        || !realWorld && pageURL.host == "127.0.0.1" && pageURL.scheme == "http"
    else { return 2 }
    // F12 opens the Chromium dock unless this hidden default is set. The shell
    // walk still posts F12, so the smoke turns the default on and puts it back.
    let defaultsKey = ShaarDevToolsRoute.legacyShellDefaultsKey
    let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
    UserDefaults.standard.set(true, forKey: defaultsKey)
    defer { restoreLegacyDefault(defaultsKey, previous: previousDefault) }
    let smokeRoot = outputURL.deletingLastPathComponent()
    let root = pageURL.query == "vitalsOnly=1" ? smokeRoot : smokeRoot.appending(path: "profile")
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
          await exercise(
            host: host, pageURL: pageURL, outputURL: outputURL, keys: keys,
            realWorld: realWorld, spaOnly: spaOnly, roundTwo: roundTwo)
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
    host: NativeBrowserHost, pageURL: URL, outputURL: URL, keys: ShaarDevToolsSmokeKeys,
    realWorld: Bool, spaOnly: Bool, roundTwo: Bool
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
    let opened = await wait(attempts: realWorld ? 180 : 900) {
      realWorld ? worldPageReady(context, pageURL) : pageReady(context, pageURL)
    }
    guard opened, let target = context.engine.siteControlTarget else {
      report.fail("page", pageDiagnostic(context, pageURL))
      return
    }
    if realWorld { try? await Task.sleep(for: .seconds(2)) }
    report.pass("page", target.url.absoluteString)
    if pageURL.query == "vitalsOnly=1" {
      await exerciseVitalsOnly(host: host, context: context, target: target, report: report)
      return
    }
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
    if spaOnly {
      await exerciseSPANavigation(
        shell: shell, inspector: inspector, context: context, report: report)
      return
    }
    if realWorld {
      await exerciseRealWorld(
        shell: shell, inspector: inspector, context: context, host: host,
        pageURL: pageURL, report: report, roundTwo: roundTwo)
      return
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
    await walkPanels(shell: shell, inspector: inspector, context: context, report: report)
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

  private static func exerciseSPANavigation(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    let clicked =
      (try? await inspector.evaluate(
        "(()=>{const link=document.querySelector('#spa-link');if(!link)return false;link.click();return true})()"
      ))
      as? Bool == true
    let navigated = await wait(attempts: 100) {
      context.engine.siteControlTarget?.url.path == "/details"
    }
    let available = await wait(attempts: 100) { shell.phase2.available }
    if clicked && navigated && available {
      report.pass("spa-nav", "Next.js Link reached /details and kept the Phase 2 lease")
    } else {
      report.fail(
        "spa-nav",
        "Link clicked=\(clicked), path changed=\(navigated), lease=\(available), stream=\(shell.streamAvailable), target=\(shell.target.url.absoluteString), phase2 error=\(shell.nativePhase2Failure ?? "none")"
      )
    }
    await shell.sources.refresh()
    if available && shell.sources.failure == nil {
      report.pass("spa-sources", "Sources command succeeded after Link navigation")
    } else {
      report.fail("spa-sources", shell.sources.failure ?? "Sources command lost its lease")
    }
  }

  private static func exerciseVitalsOnly(
    host: NativeBrowserHost, context: NativeBrowserContext, target: SiteControlTarget,
    report: ShaarDevToolsSmokeReport
  ) async {
    guard let runtime = context.engine.runtime as? ARCShaarRuntime else {
      report.fail("performance-vitals", "The Shaar runtime is unavailable")
      return
    }
    let developer = context.engine.developerModel(for: target)
    do {
      developer.setPerformanceEnabled(true)
      _ = await wait(attempts: 30) { !developer.applying }
      try await developer.refreshPerformance()
      _ = try await developer.evaluate(
        "document.getElementById('performance-input').scrollIntoView({block:'center'})")
      await settle(context)
      var clicked = false
      var trusted = false
      for _ in 0..<3 {
        clicked = await withCheckedContinuation { continuation in
          runtime.submitTrustedProbeClick(
            inTabID: target.tabID.uuidString, elementID: "performance-input"
          ) { continuation.resume(returning: $0) }
        }
        try await Task.sleep(for: .milliseconds(400))
        trusted = try await developer.evaluate("window.__qaTrustedInput===true") as? Bool == true
        if trusted { break }
      }
      try await developer.refreshPerformance()
      let snapshot = developer.performanceSnapshot
      guard await openWithF12(context: context, report: report),
        let shell = context.engine.shaarDevTools[target.tabID]
      else {
        report.fail("performance-vitals", "The Performance panel did not open")
        return
      }
      _ = await wait(attempts: 80) { shell.phase2.available || shell.nativePhase2Failure != nil }
      let selected = ShaarDevToolsSmokeAccess.press(
        identifier: "shaar.devtools.performance", in: context.hosting)
      if !selected || shell.section != .performance { shell.section = .performance }
      await settle(context)
      if shell.phase2.available { await shell.performance.refresh() }
      if let snapshot { shell.performance.updatePageSnapshot(snapshot) }
      let capture = report.directory.appending(path: "panel-performance-vitals.png")
      if !ShaarDevToolsSmokeAccess.capture(context.hosting, to: capture) {
        report.fail("capture-Performance", "Offscreen Performance capture failed")
      }
      let lcp = shell.performance.lcpMilliseconds
      let inp = shell.performance.inpMilliseconds
      if clicked, trusted, let lcp, let inp, shell.phase2.available {
        report.pass("performance-vitals", "LCP=\(lcp)ms INP=\(inp)ms trusted=true")
      } else {
        let lcpText = lcp.map { String($0) } ?? "unavailable"
        let inpText = inp.map { String($0) } ?? "unavailable"
        let detail =
          "LCP=\(lcpText) INP=\(inpText) clicked=\(clicked) trusted=\(trusted) "
          + "phase2=\(shell.phase2.available)"
        report.fail(
          "performance-vitals", detail)
      }
      if windowsHidden(host) {
        report.pass("windows", "Every window stayed hidden")
      } else {
        report.fail("windows", "A window became visible")
      }
    } catch {
      report.fail("performance-vitals", error.localizedDescription)
    }
  }

  private static func exerciseRealWorld(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    host: NativeBrowserHost, pageURL: URL, report: ShaarDevToolsSmokeReport,
    roundTwo: Bool
  ) async {
    prepareDock(shell, context: context)
    let beforeFirstReload = Date().timeIntervalSince1970
    if context.store.reloadCurrentPage() {
      let reloaded = await wait(attempts: 160) {
        worldPageReady(context, pageURL)
          && shell.network.requests(from: shell.events).contains {
            $0.startedAt > beforeFirstReload
          }
      }
      reportRealWorld(
        reloaded, "world-reload-before", "Reloaded after the live stream connected", report: report)
      try? await Task.sleep(for: .seconds(1))
    } else {
      report.fail("world-reload-before", "Initial reload was refused")
    }
    await walkRealWorldPanels(shell: shell, context: context, report: report)
    await inspectRealWorldElement(
      shell: shell, inspector: inspector, context: context, report: report)
    await filterRealWorldConsole(
      shell: shell, inspector: inspector, context: context, report: report)
    await inspectRealWorldRequest(shell: shell, context: context, report: report)
    await inspectRealWorldStorage(shell: shell, context: context, report: report)
    await performanceRecord(shell, context: context, report: report)
    if roundTwo {
      await exerciseRealWorldRoundTwo(
        shell: shell, inspector: inspector, context: context, pageURL: pageURL,
        report: report)
    }
    let beforeSecondReload = Date().timeIntervalSince1970
    if context.store.reloadCurrentPage() {
      let reloaded = await wait(attempts: 160) {
        worldPageReady(context, pageURL)
          && shell.network.requests(from: shell.events).contains {
            $0.startedAt > beforeSecondReload
          }
      }
      reportRealWorld(reloaded, "world-reload", "Same-page reload committed", report: report)
      let lease = await wait(attempts: 100) { shell.phase2.available }
      reportRealWorld(lease, "world-lease", "Live lease available after reload", report: report)
    } else {
      report.fail("world-reload", "Reload was refused")
    }
    if let target = context.engine.siteControlTarget {
      let cleared = await wait(attempts: 300) {
        context.engine.pages[target.tabID]?.loading == false
      }
      reportRealWorld(
        cleared, "world-loading", "Page loading indicator cleared within 30s", report: report)
    }
    reportRealWorld(windowsHidden(host), "windows", "Every window stayed hidden", report: report)
  }

  private static func walkRealWorldPanels(
    shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    for section in shell.sections {
      let name = section.rawValue
      let button = "shaar.devtools.\(name.lowercased())"
      let pressed = ShaarDevToolsSmokeAccess.press(identifier: button, in: context.hosting)
      if !pressed || shell.section != section { shell.section = section }
      await settle(context)
      if section == .security {
        await shell.refreshSecurity()
        try? await Task.sleep(for: .seconds(2))
        await settle(context)
      }
      let content = contentIdentifier(section)
      let appeared = await wait(attempts: 40) {
        guard let content else {
          return !ShaarDevToolsSmokeAccess.renderedText(context.hosting).isEmpty
        }
        return ShaarDevToolsSmokeAccess.element(identifier: content, in: context.hosting) != nil
      }
      let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
      var rendered =
        appeared || panelIsPainted(section, in: painted)
        || section == .issues && !shell.issues.isEmpty
        || section == .components
          && ShaarDevToolsSmokeAccess.shows("stay off for this website", in: painted)
      if section == .security {
        rendered =
          ShaarDevToolsSmokeAccess.shows("connection to this site", in: painted)
          || ShaarDevToolsSmokeAccess.shows("loaded over HTTP", in: painted)
      }
      if rendered {
        report.pass("world-panel-\(name)", "\(name) rendered")
      } else {
        report.fail(
          "world-panel-\(name)",
          panelFailure(section, shell: shell) ?? "\(name) root and content did not render")
      }
      ShaarDevToolsSmokeLook.survey(
        panel: name, contentIdentifier: content, in: context.hosting,
        failure: panelFailure(section, shell: shell), report: report)
      ShaarDevToolsSmokeLook.focus(panel: name, in: context.hosting, report: report)
      let capture = report.directory.appending(
        path: "world-\(name.replacingOccurrences(of: " ", with: "-").lowercased()).png")
      if !ShaarDevToolsSmokeAccess.capture(context.hosting, to: capture) {
        report.fail("world-capture-\(name)", "Offscreen capture failed")
      }
      if section == .security && shell.target.url.scheme == "https" {
        let identity = shell.securitySummary.certificate
        let chain = try? await context.engine.certificateChain(for: shell.target)
        let chainCount = chain?.count ?? 0
        let viewerButton =
          ShaarDevToolsSmokeAccess.element(
            identifier: "shaar.devtools.showCertificate", in: context.hosting) != nil
          || ShaarDevToolsSmokeAccess.shows(
            ShellL10n.string("Show certificate"),
            in: ShaarDevToolsSmokeAccess.renderedText(context.hosting))
        let certificate =
          identity.map { value in
            !value.subject.isEmpty && !value.issuer.isEmpty
              && value.notBefore < value.notAfter
              && !value.subjectAltNames.isEmpty
              && chainCount > 0 && value.chainSubjects.count == chainCount
              && viewerButton
          } ?? false
        let detail =
          "Identity \(identity == nil ? "absent" : "present"); SANs \(identity?.subjectAltNames.count ?? 0); chain \(chainCount); viewer button \(viewerButton)"
        reportRealWorld(
          certificate, "world-certificate", detail, report: report)
      }
    }
  }

  private static func inspectRealWorldElement(
    shell: ShaarDevToolsModel, inspector: InspectorModel,
    context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .elements
    _ = await wait(attempts: 60) { shell.dom.available && shell.dom.rootID != nil }
    await shell.dom.loadDocument(depth: 2)
    guard let body = shell.dom.nodes.values.first(where: { isBody($0) }) else {
      let names = shell.dom.nodes.values.map(\.name).sorted().prefix(12).joined(separator: ", ")
      report.fail("dom-expand", shell.dom.failure ?? "Body absent from shallow DOM: \(names)")
      report.fail("world-inspect", "Body absent from shallow DOM")
      return
    }
    if shell.dom.expanded.contains(body.id) {
      await shell.dom.toggleExpanded(body.id)
    }
    await settle(context)
    let initiallyEmpty = shell.dom.nodes[body.id]?.childrenIDs.isEmpty == true
    let disclosure = "shaar.devtools.domDisclosure.\(body.id)"
    let appeared = await wait(attempts: 40) {
      ShaarDevToolsSmokeAccess.element(identifier: disclosure, in: context.hosting) != nil
    }
    var pressed =
      appeared
      && ShaarDevToolsSmokeAccess.press(identifier: disclosure, in: context.hosting)
    if !pressed {
      for _ in 0..<4 {
        guard ShaarDevToolsSmokeAccess.press(label: "Expand node", in: context.hosting) else {
          break
        }
        pressed = true
        await settle(context)
        if shell.dom.expanded.contains(body.id) { break }
      }
    }
    if !shell.dom.expanded.contains(body.id) {
      pressed =
        ShaarDevToolsSmokeAccess.pressDisclosureText("<body>", in: context.hosting)
        || pressed
    }
    let loaded = await wait(attempts: 80) {
      (shell.dom.nodes[body.id]?.childrenIDs.count ?? 0) > 0
    }
    reportRealWorld(
      initiallyEmpty && pressed && loaded, "dom-expand",
      "Disclosure found=\(appeared), press=\(pressed), expanded=\(shell.dom.expanded.contains(body.id)), shallow children empty=\(initiallyEmpty), loaded=\(loaded); \(shell.dom.failure ?? "no error")",
      report: report)
    if loaded {
      let capture = report.directory.appending(path: "world-elements-expanded.png")
      if !ShaarDevToolsSmokeAccess.capture(context.hosting, to: capture) {
        report.fail("world-capture-expanded-elements", "Offscreen expanded Elements capture failed")
      }
    }
    shell.dom.select(body.id)
    do {
      try await inspector.selectDOMNode(body.id)
      report.pass("world-inspect", "Selected body in Elements and Inspector")
      await inspector.styles.edit(
        property: "outline", value: "3px solid rgb(17, 34, 51)", important: false)
      let result = try await inspector.evaluate("getComputedStyle(document.body).outlineWidth")
      if result as? String == "3px" {
        report.pass("world-style", "Inspector edit changed body outline to 3px")
      } else {
        report.fail(
          "world-style",
          inspector.styles.failure ?? "Outline width stayed \(String(describing: result))")
      }
    } catch {
      report.fail("world-inspect", error.localizedDescription)
      report.fail("world-style", "No selected element for style edit")
    }
  }

  private static func filterRealWorldConsole(
    shell: ShaarDevToolsModel, inspector: InspectorModel,
    context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .console
    _ = try? await inspector.evaluate("console.error('shaar-world-error')")
    let arrived = await wait(attempts: 60) {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("shaar-world-error")
      }
    }
    reportRealWorld(arrived, "world-console", "Page error reached Console", report: report)
    shell.console.level = .error
    await settle(context)
    let filtered = shell.console.rows(from: shell.consoleEvents).allSatisfy {
      $0.event.level == .error
    }
    reportRealWorld(
      filtered && arrived, "world-console-filter", "Errors filter retained the page error",
      report: report)
    shell.console.level = nil
  }

  private static func inspectRealWorldRequest(
    shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .network
    let targetPath = shell.target.url.path
    _ = await wait(attempts: 300) {
      guard let target = context.engine.siteControlTarget,
        context.engine.pages[target.tabID]?.loading == false
      else { return false }
      let rows = loadTimeDocumentRows(shell: shell, path: targetPath)
      return !rows.isEmpty && rows.allSatisfy { $0.method == "GET" }
    }
    let initial = shell.network.requests(from: shell.events)
    let documentRows = loadTimeDocumentRows(shell: shell, path: targetPath)
    let hasDocument = !documentRows.isEmpty && documentRows.allSatisfy { $0.method == "GET" }
    let documentDetails = documentRows.map {
      "id=\($0.id) method=\($0.method.isEmpty ? "<empty>" : $0.method) status=\($0.status.map(String.init) ?? "-")"
    }.joined(separator: "; ")
    let paths = initial.prefix(12).compactMap { URL(string: $0.url)?.path }.joined(separator: ", ")
    reportRealWorld(
      hasDocument, "world-network-load",
      "Load-time document in \(initial.count) requests (rows: \(documentDetails); first paths: \(paths))",
      report: report)
    if let inspector = context.engine.siteControlTarget.flatMap({
      context.engine.inspectors[$0.tabID]
    }) {
      _ = try? await inspector.evaluate(
        "fetch(location.pathname + '?shaarWorld=1', {cache:'no-store'}).then(r=>r.text())")
    }
    let loaded = await wait(attempts: 80) {
      shell.network.requests(from: shell.events).contains {
        $0.url.contains("shaarWorld=1") && $0.status == 200
      }
    }
    let rows = shell.network.requests(from: shell.events)
    let har = report.directory.appending(path: "world-network.har")
    _ = try? ShaarNetworkHAR.write(shell.network.exportRequests(from: shell.events), to: har)
    guard loaded,
      let request = rows.first(where: {
        $0.url.contains("shaarWorld=1") && $0.status == 200
      })
    else {
      report.fail("world-request", "No completed 200 request in Network")
      return
    }
    shell.network.selectedID = request.id
    await settle(context)
    let headers = !request.requestHeaders.isEmpty && !request.responseHeaders.isEmpty
    reportRealWorld(
      headers, "world-headers",
      "Request and response headers for \(request.name): \(request.requestHeaders.count)/\(request.responseHeaders.count)",
      report: report)
    await shell.network.loadResponseBody(id: request.id)
    shell.network.detailTab = .response
    await settle(context)
    let selected = shell.network.exportRequests(from: shell.events).first { $0.id == request.id }
    reportRealWorld(
      selected?.responseBody?.isEmpty == false, "world-response",
      "Response body for \(request.name)", report: report)
    shell.network.detailTab = .timing
    await settle(context)
    let completed = await wait(attempts: 50) {
      shell.network.requests(from: shell.events).first { $0.id == request.id }?.duration != nil
    }
    reportRealWorld(completed, "world-timing", "Timing for \(request.name)", report: report)
  }

  private static func loadTimeDocumentRows(
    shell: ShaarDevToolsModel, path: String
  ) -> [ShaarNetworkRequest] {
    shell.network.requests(from: shell.events).filter {
      $0.resource == .document && URL(string: $0.url)?.path == path
    }
  }

  private static func inspectRealWorldStorage(
    shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .application
    for area in ShaarApplicationArea.allCases {
      shell.application.selectArea(area)
      if area == .cookies {
        await shell.cookies.refresh()
      } else {
        await shell.application.refresh()
      }
      let finished = await wait(attempts: 40) { !shell.application.loading }
      await settle(context)
      let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
      let count: Int
      switch area {
      case .cookies: count = shell.cookies.cookies.count
      case .workers: count = shell.application.workers.count
      default: count = shell.application.rows.count
      }
      let empty: String
      switch area {
      case .cookies: empty = "No cookies for this page"
      case .local, .session: empty = "No storage items for this page"
      case .indexedDB: empty = "No IndexedDB data for this page"
      case .cache: empty = "No cached resources for this page"
      case .workers: empty = "No service workers for this page"
      }
      let visible = count > 0 || ShaarDevToolsSmokeAccess.shows(empty, in: painted)
      let failure = area == .cookies ? shell.cookies.failure : shell.application.failure
      if finished, failure == nil, visible {
        report.pass(
          "world-storage-\(area.rawValue)", "\(area.rawValue): \(count) rows or visible empty state"
        )
      } else {
        report.fail(
          "world-storage-\(area.rawValue)",
          failure ?? "\(area.rawValue) stayed loading or lacked its empty state")
      }
    }
  }

  private static func reportRealWorld(
    _ passed: Bool, _ name: String, _ detail: String, report: ShaarDevToolsSmokeReport
  ) {
    if passed { report.pass(name, detail) } else { report.fail(name, detail) }
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
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    report.note(
      "painted-text",
      "A hidden window does not expose SwiftUI controls in the accessibility tree. The smoke reads the offscreen bitmap, and runs the button action when the press does not land."
    )
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
      if section == .cssOverview {
        _ = await cssOverviewSettled(shell)
      }
      await settle(context)
      let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
      recordTab(
        section, pressed: pressed && shell.section == section, painted: painted, report: report)
      recordSidebarTitle(painted, report: report)
      await provePanel(section, shell: shell, context: context, painted: painted, report: report)
      if section == .components {
        await proveComponentAccessors(shell, inspector: inspector, report: report)
      }
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
      if section == .components {
        await proveComponentAccessorInvocation(
          shell, inspector: inspector, context: context, report: report)
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

  private static func proveComponentAccessors(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    _ = await wait(attempts: 40) { shell.framework.inspected && !shell.framework.loading }
    let field = shell.framework.nodes.flatMap(\.props)
      .first { $0.name == "accessorProbe" }
    let summary = field?.value
    let calls = (try? await inspector.evaluate("globalThis.inspectorGetterCalls || 0")) as? Int
    if summary?.contains("(...)") == true, field?.accessors.contains("danger") == true,
      calls == 0
    {
      report.pass("components-accessors", "Props show (...) without running the page getter")
    } else {
      report.fail(
        "components-accessors",
        "Accessor summary: \(summary ?? "missing"); getter calls: \(calls.map(String.init) ?? "unknown")",
        severity: .broken)
    }
  }

  private static func proveComponentAccessorInvocation(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    guard let field = shell.framework.selected?.props.first(where: { $0.name == "accessorProbe" })
    else {
      report.fail("components-accessor-invoke", "The selected component has no accessor probe")
      return
    }
    let identifier = "shaar.devtools.components.invoke.\(field.id).danger"
    let pressed = ShaarDevToolsSmokeAccess.press(identifier: identifier, in: context.hosting)
    let invoked = await wait(attempts: 30) {
      shell.framework.selected?.props.first(where: { $0.name == "accessorProbe" })?
        .invoked["danger"] == "unexpected"
    }
    let calls = (try? await inspector.evaluate("globalThis.inspectorGetterCalls || 0")) as? Int
    if pressed, invoked, calls == 1 {
      report.pass("components-accessor-invoke", "Offscreen click invoked the getter once")
    } else {
      let foundByID =
        ShaarDevToolsSmokeAccess.element(identifier: identifier, in: context.hosting) != nil
      report.fail(
        "components-accessor-invoke",
        "Found ID: \(foundByID); pressed: \(pressed); invoked: \(invoked); getter calls: \(calls.map(String.init) ?? "unknown")",
        severity: .broken)
    }
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
      let idleBanner =
        ShaarDevToolsSmokeAccess.element(
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
      let note =
        ShaarDevToolsSmokeAccess.element(
          identifier: "shaar.devtools.rendering.overlayNote", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("Paint flashing waits", in: painted)
      if shell.rendering.overlayCommandsAvailable, !note {
        report.pass(name, "Paint flashing is available")
      } else {
        report.fail(
          name, shell.rendering.failure ?? "Rendering overlay still waits for an engine build")
      }
    case .memory:
      let gate =
        ShaarDevToolsSmokeAccess.element(
          identifier: "shaar.devtools.memory.engineGate", in: context.hosting) != nil
        || ShaarDevToolsSmokeAccess.shows("Live heap snapshots need engine support", in: painted)
      if gate {
        report.fail(name, "Memory shows a needs-engine banner")
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
        report.pass(name, "Audits rendered")
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
      provePainted(
        name, section: section, root: panelRoot(section), painted: painted, in: context,
        report: report)
      await proveLoadRequests(shell, report: report)
      if shell.network.requests(from: shell.events).isEmpty {
        report.fail(
          "network-stale",
          "Network says there are no requests after the fixture loaded /qa, /api/items, and /api/xhr.",
          severity: .wrong)
      }
    case .performance, .sources:
      if !shell.phase2.available {
        let reason = shell.nativePhase2Failure ?? "the live lease is not connected"
        report.fail(name, "Shows the unavailable banner. \(reason)")
        return
      }
      provePainted(
        name, section: section, root: panelRoot(section), painted: painted, in: context,
        report: report)
    default:
      provePainted(
        name, section: section, root: panelRoot(section), painted: painted, in: context,
        report: report)
    }
  }

  private static func proveLoadRequests(
    _ shell: ShaarDevToolsModel, report: ShaarDevToolsSmokeReport
  ) async {
    let expected: Set<String> = [
      "/qa", "/qa.css", "/frameworks.js", "/pixel.png", "/api/items", "/api/xhr",
    ]
    let complete = await wait(attempts: 50) {
      expected.isSubset(of: loadRequestPaths(shell))
    }
    let seen = loadRequestPaths(shell)
    if complete {
      report.pass("network-load", "Document, stylesheet, script, image, fetch, and XHR arrived")
    } else {
      let missing = expected.subtracting(seen).sorted().joined(separator: ", ")
      let present = seen.sorted().joined(separator: ", ")
      report.fail(
        "network-load", "Missing load-time requests: \(missing). Seen: \(present)",
        severity: .wrong)
    }
  }

  private static func loadRequestPaths(_ shell: ShaarDevToolsModel) -> Set<String> {
    Set(shell.network.requests(from: shell.events).compactMap { URL(string: $0.url)?.path })
  }

  private static func showsBanner(_ sentence: String, painted: String, in root: NSView) -> Bool {
    if ShaarDevToolsSmokeAccess.shows(sentence, in: painted) { return true }
    return ShaarDevToolsSmokeAccess.element(label: sentence, in: root) != nil
  }

  private static func provePainted(
    _ name: String, section: ShaarDevToolsSection, root: String?, painted: String,
    in context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) {
    let found =
      root.map {
        ShaarDevToolsSmokeAccess.element(identifier: $0, in: context.hosting) != nil
      } ?? false
    let blocked =
      ShaarDevToolsSmokeAccess.element(
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
    await ShaarDevToolsSmokeExercise.run(
      shell: shell, inspector: inspector, context: context, report: report)
    await coverageRoundTrip(shell, context: context, report: report)
    await touchRoundTrip(shell, context: context, report: report)
    await memorySnapshot(shell, context: context, report: report)
    await consoleEvaluate(shell, inspector: inspector, context: context, report: report)
    await consoleFilters(shell, context: context, report: report)
    await networkActions(shell, inspector: inspector, context: context, report: report)
    await applicationStorage(shell, context: context, report: report)
    await performanceRecord(shell, context: context, report: report)
    await recorderRoundTrip(shell, inspector: inspector, context: context, report: report)
    await renderingPaint(shell, context: context, report: report)
    await cssReload(shell, context: context, report: report)
    await ShaarDevToolsSmokeMedia.run(context: context, report: report)
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
    let pressedStart = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.coverageStart", in: context.hosting)
    guard pressedStart else {
      report.fail("coverage-record", "Start could not be pressed in the hidden panel")
      return
    }
    let started = await wait(attempts: 40) {
      shell.coverage.recording || shell.coverage.notice != nil
    }
    guard started, shell.coverage.recording else {
      report.fail(
        "coverage-record",
        shell.coverage.notice.map(String.init(describing:)) ?? "Start did nothing")
      return
    }
    let pressedStop = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.coverageStop", in: context.hosting)
    guard pressedStop else {
      report.fail("coverage-record", "Stop could not be pressed in the hidden panel")
      return
    }
    let stopped = await wait(attempts: 40) { !shell.coverage.recording }
    if stopped, shell.coverage.notice == nil,
      shell.coverage.rows.contains(where: { $0.totalBytes > 0 && $0.usedBytes > 0 })
    {
      report.pass("coverage-record", "Start and Stop ran. Rows \(shell.coverage.rows.count)")
    } else {
      report.fail(
        "coverage-record",
        shell.coverage.notice.map(String.init(describing:)) ?? "No used coverage row after Stop")
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
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.sensorTouch", in: context.hosting)
    if !pressed || !shell.sensorTouch { shell.setSensorTouch(true) }
    _ = await wait(attempts: 15) {
      if case .failed = shell.sensorNotice { return true }
      return false
    }
    if case .failed(let message) = shell.sensorNotice {
      report.fail("touch", message)
    } else if shell.sensorTouch {
      let detail =
        pressed
        ? "The touch switch sent the emulation"
        : "The touch action sent the emulation"
      report.pass("touch", detail)
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
      shell.memory.snapshot != nil || shell.memory.failure != nil
        || shell.memory.support == .needsEngine
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
      report.fail(
        "network-cache", shell.network.conditions.failure ?? "Disable cache did not stick")
    }
    await ShaarNetworkMenuActions.chooseThrottle(.fast3G, conditions: shell.network.conditions)
    if shell.network.conditions.throttle == .fast3G, shell.network.conditions.failure == nil {
      await ShaarNetworkMenuActions.chooseThrottle(.none, conditions: shell.network.conditions)
      report.pass("network-throttle", "The throttle menu selected Fast 3G and cleared it")
    } else {
      report.fail(
        "network-throttle",
        shell.network.conditions.failure ?? "The throttle menu did nothing")
    }
    let harPainted =
      ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.networkHAR", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows(
        "Export HAR", in: ShaarDevToolsSmokeAccess.renderedText(context.hosting))
    let harURL = report.directory.appending(path: "qa-network.har")
    let requests = shell.network.exportRequests(from: shell.events)
    let wrote = (try? ShaarNetworkHAR.write(requests, to: harURL)) != nil
    let entries = harEntryCount(at: harURL)
    if harPainted, wrote, entries > 0 {
      report.pass(
        "network-har",
        "Export HAR wrote \(entries) entries to a temp file. The save panel was not opened.")
    } else if requests.isEmpty || entries == 0 {
      report.fail("network-har", "Export HAR had nothing to write", severity: .wrong)
    } else if !wrote {
      report.fail("network-har", "Export HAR did not write the temp file")
    } else {
      report.fail("network-har", "Export HAR was missing")
    }
    let pressedRules = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.networkRules", in: context.hosting)
    if !pressedRules { shell.rules.showingRules = true }
    await settle(context)
    let rulesPainted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
    let rulesMissing =
      ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.networkRulesUnavailable", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("Network rules need engine support", in: rulesPainted)
    let rulesOpen =
      shell.rules.showingRules
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
      let board = NSPasteboard(name: NSPasteboard.Name("shaar.devtools.smoke.curl"))
      ShaarNetworkMenuActions.copyCurl(request, model: shell.network, to: board)
      let copied = board.string(forType: .string) ?? ""
      if copied.contains("curl"), copied.contains(request.url) {
        report.pass("network-curl", "The Copy as cURL menu wrote the request")
      } else if copied.contains("curl") {
        report.fail(
          "network-curl", "Copy as cURL omitted the request URL", severity: .wrong)
      } else {
        report.fail(
          "network-curl", "The Copy as cURL menu did nothing", severity: .broken)
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
    shell.dock = .right
    await settle(context)
    await ShaarDevToolsSmokeExercise.dragSplit(shell: shell, context: context, report: report)
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
        || ShaarDevToolsSmokeAccess.element(
          identifier: "shaar.devtools.domRow", in: context.hosting)
          != nil
        || ShaarDevToolsSmokeAccess.element(
          identifier: "shaar.devtools.domUnavailable", in: context.hosting) != nil
    }
    let unavailable =
      ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.domUnavailable", in: context.hosting) != nil
      || ShaarDevToolsSmokeAccess.shows("DOM tree needs engine support", in: painted)
    let blocked =
      ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.streamUnavailable", in: context.hosting) != nil
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.domRow", in: context.hosting)
    if ready, unavailable == false, blocked == false, shell.dom.rootID != nil {
      let how = pressed ? "A DOM row was pressed" : "The DOM tree is on screen"
      report.pass(name, how)
    } else {
      report.fail(name, shell.dom.failure ?? "Elements did not show the DOM tree")
    }
    await proveEventListeners(shell, context: context, report: report)
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

  private static func isBody(_ node: ShaarDOMNode) -> Bool {
    node.nodeType == 1 && node.name.caseInsensitiveCompare("BODY") == .orderedSame
  }

  private static func selectListenerFixtureNode(_ dom: ShaarDOMTreeModel) async -> Bool {
    let loaded = await wait(attempts: 80) { dom.rootID != nil && !dom.loading }
    guard loaded else { return false }
    if let body = dom.nodes.values.first(where: isBody) {
      dom.select(body.id)
      return true
    }
    dom.search = "body"
    await dom.performSearch()
    guard let body = dom.nodes.values.first(where: isBody) else { return false }
    dom.select(body.id)
    return true
  }

  /// The pane title used to pass while the body still said the selected node was missing.
  private static func proveEventListeners(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    var detail = "The fixture body could not be selected"
    for _ in 0..<3 {
      guard await selectListenerFixtureNode(shell.dom), let selected = shell.dom.selectedID else {
        break
      }
      let ancestors = ShaarEventListenerAncestors.chain(from: selected, nodes: shell.dom.nodes)
      await shell.listeners.load(nodeID: selected, ancestors: ancestors)
      let settled = await wait(attempts: 40) { !shell.listeners.loading }
      let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
      let failure = shell.listeners.failure ?? ""
      let missing =
        failure.localizedCaseInsensitiveContains("no node with given id")
        || ShaarDevToolsSmokeAccess.shows("No node with given id found", in: painted)
      let selectedBody =
        shell.dom.selectedID == selected && shell.dom.nodes[selected].map(isBody) == true
      let listed = shell.listeners.listeners.contains { $0.type == "qa-ping" }
      if settled, selectedBody, missing == false, listed {
        report.pass("elements-listeners", "Event listeners lists qa-ping on the selected body")
        let url = report.directory.appending(path: "panel-elements-listeners.png")
        if !ShaarDevToolsSmokeAccess.capture(context.hosting, to: url) {
          report.fail("capture-elements-listeners", "Event listeners offscreen capture failed")
        }
        return
      }
      if missing {
        detail = failure.isEmpty ? "No node with given id found" : failure
      } else if selectedBody {
        detail = failure.isEmpty ? "Event listeners did not list qa-ping" : failure
      } else {
        detail = "The fixture body selection changed during the listener read"
      }
    }
    report.fail("elements-listeners", detail)
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
    _ = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.consoleEntry", in: context.hosting)
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
    if !shell.phase2.available {
      report.fail(
        "storage-\(area.rawValue)",
        "\(label) is unavailable because the live lease is not connected")
      return
    }
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
    } else if shell.application.loading {
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
    if !shell.phase2.available {
      report.fail(
        "storage-workers",
        "Service workers are unavailable because the live lease is not connected")
      return
    }
    let found = await wait(attempts: 40) {
      !shell.application.loading
        && (shell.application.failure != nil || !shell.application.workers.isEmpty)
    }
    let registered = shell.application.workers.contains { $0.scriptURL.contains("sw.js") }
    if found, shell.application.failure == nil, registered {
      report.pass("storage-workers", "Service worker sw.js is registered")
    } else if let failure = shell.application.failure {
      report.fail("storage-workers", failure)
    } else if shell.application.loading {
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
      report.fail(
        "performance-record", shell.performance.failure ?? "Record did not start and stop")
    }
  }

  private static func recorderRoundTrip(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
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
    _ = try? await inspector.evaluate("document.getElementById('long')?.click()")
    let pressedStop = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.recorderStop", in: context.hosting)
    if !pressedStop { await shell.recorder.stop() }
    let stopped = await wait(attempts: 30) { !shell.recorder.recording }
    if stopped, shell.recorder.notice == nil {
      report.pass("recorder", "Record and Stop ran")
    } else {
      report.fail("recorder", noticeText(shell.recorder.notice) ?? "Stop did not finish")
      return
    }
    await exportRecording(shell, context: context, report: report)
  }

  private static func exportRecording(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let captured = !shell.recorder.steps.isEmpty
    guard captured else {
      report.fail("recorder-export", "Export stayed disabled because recording captured no steps")
      return
    }
    let directory = context.engine.runtime.downloadsDirectory(
      forProfileID: shell.target.profileID.uuidString)
    guard let directory else {
      report.fail("recorder-export", "Export needs the profile downloads folder")
      return
    }
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.recorderExport", in: context.hosting)
    var exportError: String?
    if !pressed {
      exportError = writeFlow(shell, to: directory)
    }
    let saved = await wait(attempts: 20) {
      !flowFiles(in: directory).isEmpty || shell.recorder.notice == .saved
    }
    if !saved {
      exportError = writeFlow(shell, to: directory) ?? exportError
    }
    let files = flowFiles(in: directory)
    if let file = files.first, flowDocument(at: file) {
      report.pass("recorder-export", "Export wrote \(file.lastPathComponent)")
    } else if files.isEmpty {
      report.fail(
        "recorder-export",
        noticeText(shell.recorder.notice) ?? exportError ?? "Export did nothing")
    } else {
      report.fail("recorder-export", "Export wrote a file that is not a flow", severity: .wrong)
    }
  }

  private static func writeFlow(_ shell: ShaarDevToolsModel, to directory: URL) -> String? {
    do {
      _ = try shell.recorder.exportFile(in: directory)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private static func flowFiles(in directory: URL) -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    return names.filter {
      $0.lastPathComponent.hasPrefix("shaar-flow-") && $0.pathExtension == "json"
    }
  }

  private static func flowDocument(at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    let steps = json["steps"] as? [Any]
    return steps?.isEmpty == false
  }

  private static func harEntryCount(at url: URL) -> Int {
    guard let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let log = json["log"] as? [String: Any],
      let entries = log["entries"] as? [Any]
    else { return 0 }
    return entries.count
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
    _ = await cssOverviewSettled(shell)
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.cssReload", in: context.hosting)
    if pressed {
      _ = await wait(attempts: 20) { shell.cssOverview.loading }
    } else {
      await shell.cssOverview.reload(force: true)
    }
    var finished = await cssOverviewSettled(shell)
    if cssFixtureNeedsAnotherRead(shell, finished: finished) {
      await shell.cssOverview.reload(force: true)
      finished = await cssOverviewSettled(shell)
    }
    reportCSSOverview(shell, finished: finished, report: report)
    captureCSSOverview(context, report: report)
    reportCSSDeclarationLabel(context, report: report)
  }

  private static func reportCSSDeclarationLabel(
    _ context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) {
    let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
    let singular = painted.range(of: "\\b1 declaration\\b(?!s)", options: .regularExpression) != nil
    if singular {
      report.pass("css-declaration-label", "One-count CSS rows use the singular label")
    } else {
      report.fail(
        "css-declaration-label", "One-count CSS rows did not show '1 declaration'",
        severity: .polish)
    }
  }

  private static func cssOverviewSettled(_ shell: ShaarDevToolsModel) async -> Bool {
    await wait(attempts: 40) {
      !shell.cssOverview.loading && (shell.cssOverview.loaded || shell.cssOverview.failure != nil)
    }
  }

  private static func cssFixtureNeedsAnotherRead(
    _ shell: ShaarDevToolsModel, finished: Bool
  ) -> Bool {
    guard finished, shell.cssOverview.loaded, shell.cssOverview.failure == nil else { return false }
    return cssFixtureGap(shell.cssOverview.summary) != nil
  }

  private static func reportCSSOverview(
    _ shell: ShaarDevToolsModel, finished: Bool, report: ShaarDevToolsSmokeReport
  ) {
    if finished, shell.cssOverview.loaded, shell.cssOverview.failure == nil,
      cssFixtureGap(shell.cssOverview.summary) == nil
    {
      report.pass(
        "css-overview",
        "Reload counted the inline style, the linked sheet, and the sheet added by the page")
      return
    }
    if finished, shell.cssOverview.loaded, shell.cssOverview.failure == nil,
      let gap = cssFixtureGap(shell.cssOverview.summary)
    {
      report.fail(
        "css-overview",
        "CSS overview missed fixture sheets (\(gap)).",
        severity: .wrong)
      return
    }
    report.fail("css-overview", shell.cssOverview.failure ?? "CSS overview did not load")
  }

  /// Missing fixture colors. Nil means the inline sheet, the linked sheet, and
  /// the sheet the page added are all present.
  private static func cssFixtureGap(_ summary: ShaarDevToolsCSSSummary) -> String? {
    let labels = summary.colors.map { $0.label.lowercased().filter { !$0.isWhitespace } }
    var missing: [String] = []
    if summary.examined < 3 {
      missing.append("examined \(summary.examined)")
    }
    if !labels.contains(where: { $0.contains("172033") }) { missing.append("#172033") }
    if !labels.contains(where: isLinkedFixtureColor) { missing.append("#c2410c") }
    if !labels.contains(where: { $0.contains("0f766e") }) { missing.append("#0f766e") }
    guard !missing.isEmpty else { return nil }
    return "missing \(missing.joined(separator: ", "))"
  }

  private static func isLinkedFixtureColor(_ label: String) -> Bool {
    label.contains("c2410c") || label == "rgb(194,65,12)"
  }

  private static func captureCSSOverview(
    _ context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) {
    let url = report.directory.appending(path: "panel-css-overview.png")
    _ = ShaarDevToolsSmokeAccess.capture(context.hosting, to: url)
  }

  private static func restoreLegacyDefault(_ key: String, previous: Any?) {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private static func postedF12(_ context: NativeBrowserContext) -> Bool {
    guard
      let event = NSEvent.keyEvent(
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
    return
      "No committed web page. target=\(address) selected=\(selected) loading=\(loading) liveTabs=\(live) notice=\(notice) expected=\(pageURL.absoluteString)"
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

  static func settle(_ context: NativeBrowserContext) async {
    context.hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(150))
    context.hosting.layoutSubtreeIfNeeded()
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget else { return false }
    guard target.url.path == pageURL.path else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func worldPageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget else { return false }
    return target.url.host == pageURL.host && context.engine.pages[target.tabID] != nil
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    host.contexts.values.allSatisfy { !$0.window.isVisible }
      && NSApp.windows.allSatisfy { !$0.isVisible }
  }

  static func wait(attempts: Int, until ready: () -> Bool) async -> Bool {
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
    case .cssOverview:
      [
        "style sheets", "This page has no style", "Colors", "Fonts", "Sheets", "declaration",
      ]
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

  func manual(_ name: String, _ detail: String) {
    append(name, passed: true, detail, severity: .ok, outcome: "needs-manual")
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
    _ name: String, passed: Bool, _ detail: String, severity: ShaarDevToolsSmokeSeverity,
    outcome: String? = nil
  ) {
    let place = Self.placement(name)
    var step: [String: Any] = [
      "name": name,
      "panel": place.panel,
      "action": place.action,
      "passed": passed,
      "severity": severity.rawValue,
      "detail": detail,
    ]
    if let outcome { step["outcome"] = outcome }
    steps.append(step)
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
    if let panel = prefixed(name, "world-panel-") { return (panel, "Open panel") }
    if let panel = prefixed(name, "world-capture-") { return (panel, "Offscreen capture") }
    if let area = prefixed(name, "world-storage-") { return ("Application", area) }
    switch name {
    case "page": return ("Session", "Open fixture")
    case "f12": return ("Session", "Press F12")
    case "performance-vitals": return ("Performance", "Measure LCP and INP")
    case "world-inspect": return ("Elements", "Inspect body")
    case "world-style": return ("Elements", "Edit style")
    case "world-console": return ("Console", "Page error")
    case "world-console-filter": return ("Console", "Errors filter")
    case "world-request": return ("Network", "Select request")
    case "world-network-load": return ("Network", "Load-time document")
    case "world-headers": return ("Network", "Headers")
    case "world-response": return ("Network", "Response")
    case "world-timing": return ("Network", "Timing")
    case "world2-elements-search": return ("Elements", "Search body")
    case "world2-elements-attribute": return ("Elements", "Edit attribute")
    case "world2-console-object": return ("Console", "Expand object")
    case "world2-console-nested": return ("Console", "Expand nested object")
    case "world2-console-multiline": return ("Console", "Multiline eval")
    case "world2-source-open": return ("Sources", "Open source")
    case "world2-source-pretty": return ("Sources", "Pretty print")
    case "world2-source-map": return ("Sources", "Source map")
    case "world2-source-map-content": return ("Sources", "Open original source")
    case "world2-network-volume": return ("Network", "100+ requests")
    case "world2-network-filter": return ("Network", "Filter chip")
    case "world2-network-search": return ("Network", "Search")
    case "world2-network-fetch": return ("Network", "Copy as fetch")
    case "world2-network-har": return ("Network", "Export HAR")
    case "world2-websocket": return ("Network", "WebSocket")
    case "world2-service-worker": return ("Application", "Service worker")
    case "world2-cookie-edit": return ("Application", "Edit cookie")
    case "world2-cookie-delete": return ("Application", "Delete cookie")
    case "world2-performance-long-task": return ("Performance", "Long task")
    case "world2-dock-bottom": return ("Chrome", "Dock bottom")
    case "world2-dock-right": return ("Chrome", "Dock right")
    case "world2-theme-light": return ("Chrome", "Light mode")
    case "world2-theme-dark": return ("Chrome", "Dark mode")
    case "world2-keyboard": return ("Chrome", "Keyboard navigation")
    case "world2-hmr": return ("Session", "Hot reload")
    case "world2-spa": return ("Session", "SPA navigation")
    case "world-certificate": return ("Security", "Certificate identity")
    case "world-loading": return ("Session", "Loading indicator")
    case "world-reload-before": return ("Session", "Reload after stream")
    case "world-reload": return ("Session", "Reload mid-session")
    case "world-lease": return ("Session", "Lease after reload")
    case "stream": return ("Session", "Live stream")
    case "phase2": return ("Session", "Phase 2 lease")
    case "fixture": return ("Session", "Fixture ready")
    case "windows", "windows-final": return ("Session", "Windows stay hidden")
    case "quit-open": return ("Session", "Quit with DevTools open")
    case "restore": return ("Session", "Restore hidden window")
    case "coverage-record": return ("Coverage", "Start and stop")
    case "media-capture": return ("Media", "Camera and microphone in use")
    case "media-stop": return ("Media", "Capture stops")
    case "touch": return ("Sensors", "Toggle touch")
    case "memory-snapshot": return ("Memory", "Take heap snapshot")
    case "console": return ("Console", "Evaluate 6*7")
    case "console-filter": return ("Console", "Errors filter")
    case "console-filter-all": return ("Console", "All filter")
    case "console-stack": return ("Console", "Stack trace")
    case "console-clear": return ("Console", "Clear")
    case "network-rows": return ("Network", "Request rows")
    case "network-load": return ("Network", "Load-time requests")
    case "network-stale": return ("Network", "Request list")
    case "issues-badge": return ("Issues", "Badge count")
    case "painted-text": return ("Session", "How panels are read")
    case "network-cache": return ("Network", "Disable cache")
    case "network-throttle": return ("Network", "Throttle menu")
    case "network-har": return ("Network", "HAR save")
    case "network-rules": return ("Network", "Rules editor")
    case "network-curl": return ("Network", "Copy as cURL menu")
    case "inspector-styles": return ("Elements", "Styles")
    case "inspector-computed": return ("Elements", "Computed")
    case "inspector-box": return ("Elements", "Box model")
    case "inspector-force": return ("Elements", "Force state")
    case "inspector-a11y": return ("Elements", "Accessibility tree")
    case "inspector-stale": return ("Elements", "Computed stays current")
    case "dom-expand": return ("Elements", "Expand row")
    case "dom-drag": return ("Elements", "DOM drag")
    case "dom-selector": return ("Elements", "Copy selector")
    case "audit-run": return ("Audits", "Run audit")
    case "certificate": return ("Security", "Show certificate")
    case "recorder-export": return ("Recorder", "Export")
    case "elements-listeners": return ("Elements", "Event listeners")
    case "elements-search": return ("Elements", "Search")
    case "performance-record": return ("Performance", "Record and stop")
    case "recorder": return ("Recorder", "Record and stop")
    case "rendering-paint": return ("Rendering", "Paint flashing")
    case "css-overview": return ("CSS overview", "Reload")
    case "css-declaration-label": return ("CSS overview", "Declaration label")
    case "components-accessors": return ("Components", "Read accessor props")
    case "components-accessor-invoke": return ("Components", "Invoke accessor")
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
  @MainActor static func sendRightArrow(in root: NSView) -> Bool {
    guard let window = root.window, !window.isVisible,
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
        isARepeat: false, keyCode: 124)
    else { return false }
    window.sendEvent(event)
    return true
  }

  @MainActor static func pressDisclosureText(_ label: String, in root: NSView) -> Bool {
    pressText(label, onText: false, in: root)
  }

  @MainActor static func pressVisibleText(
    _ label: String, in root: NSView, region: CGRect
  ) -> Bool {
    pressText(label, onText: true, in: root, region: region)
  }

  @MainActor private static func pressText(
    _ label: String, onText: Bool, in root: NSView, region: CGRect? = nil
  ) -> Bool {
    root.layoutSubtreeIfNeeded()
    guard let window = root.window, !window.isVisible,
      let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)
    else { return false }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    guard let image = bitmap.cgImage else { return false }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil,
      let row = request.results?.first(where: { result in
        let center = CGPoint(x: result.boundingBox.midX, y: result.boundingBox.midY)
        return (region?.contains(center) ?? true)
          && result.topCandidates(1).first?.string.localizedCaseInsensitiveContains(label) == true
      })
    else { return false }
    let x: CGFloat
    if onText {
      x = row.boundingBox.midX * root.bounds.width
    } else {
      x = row.boundingBox.minX * root.bounds.width - 12
    }
    let imageY = row.boundingBox.midY * root.bounds.height
    let y = root.isFlipped ? root.bounds.height - imageY : imageY
    let point = root.convert(CGPoint(x: x, y: y), to: nil)
    guard let down = mouseEvent(.leftMouseDown, at: point, window: window),
      let up = mouseEvent(.leftMouseUp, at: point, window: window)
    else { return false }
    window.sendEvent(down)
    window.sendEvent(up)
    return true
  }

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
    if let button = object as? NSButton, button.isEnabled {
      button.performClick(nil)
      return true
    }
    if let view = object as? NSView {
      if view.accessibilityPerformPress() { return true }
      return pressHidden(view)
    }
    if let element = object as? NSAccessibilityElement {
      return element.accessibilityPerformPress()
    }
    return false
  }

  @MainActor static func drag(_ view: NSView, by delta: CGSize) -> Bool {
    guard let window = view.window, !window.isVisible else { return false }
    let start = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let end = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
    guard let down = mouseEvent(.leftMouseDown, at: start, window: window),
      let moved = mouseEvent(.leftMouseDragged, at: end, window: window),
      let up = mouseEvent(.leftMouseUp, at: end, window: window)
    else { return false }
    view.mouseDown(with: down)
    view.mouseDragged(with: moved)
    view.mouseUp(with: up)
    return true
  }

  @MainActor private static func pressHidden(_ view: NSView) -> Bool {
    guard let window = view.window, !window.isVisible else { return false }
    let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    guard let down = mouseEvent(.leftMouseDown, at: point, window: window),
      let up = mouseEvent(.leftMouseUp, at: point, window: window)
    else { return false }
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    return true
  }

  @MainActor private static func mouseEvent(
    _ type: NSEvent.EventType, at point: CGPoint, window: NSWindow
  ) -> NSEvent? {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
      pressure: type == .leftMouseDown ? 1 : 0)
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

  @MainActor private static func matches(_ object: NSObject, identifier: String?, label: String?)
    -> Bool
  {
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

private typealias ShaarDevToolsSmokeWindowOrder =
  @convention(c) (AnyObject, Selector, Int, Int) -> Void
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
    shaarDevToolsSmokePreviousOrder = unsafeBitCast(
      original, to: ShaarDevToolsSmokeWindowOrder.self)
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
