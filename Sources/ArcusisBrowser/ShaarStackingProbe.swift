// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Opens the 3D stacking panel on a hidden page, captures slabs, and selects one in Elements.
@MainActor enum ShaarStackingProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, allows(pageURL) else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let crashesBefore = crashNames()
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
        presentation: .hiddenProbe)
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await exercise(
            host: host, pageURL: pageURL, outputURL: outputURL, crashesBefore: crashesBefore)
        }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(
        ["passed": false, "error": error.localizedDescription, "newCrashReports": []],
        to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, pageURL: URL, outputURL: URL, crashesBefore: Set<String>
  ) async {
    defer { host.events.quit() }
    do { try host.restore() } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["passed": false, "error": "No hidden browser context"], to: outputURL)
      return
    }
    context.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 860), display: false)
    context.hosting.frame = context.contentView.bounds
    context.store.perform(.open(pageURL))
    let opened = await wait(attempts: 300) { pageReady(context, pageURL) }
    guard opened, let target = context.engine.siteControlTarget else {
      write(["passed": false, "error": "No committed web page"], to: outputURL)
      return
    }
    context.engine.toggleDeveloperTools()
    let tools = await wait(attempts: 40) {
      context.engine.shaarDevTools[target.tabID]?.isOpen == true
    }
    guard tools, let shell = context.engine.shaarDevTools[target.tabID] else {
      write(["passed": false, "error": "DevTools did not open"], to: outputURL)
      return
    }
    shell.dock = .bottom
    shell.bottomHeight = 520
    let domReady = await wait(attempts: 80) { shell.dom.available }
    _ = ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.3d view", in: context.hosting)
    if shell.section != .stacking { shell.section = .stacking }
    await settle(context)
    let pressedCapture = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.stacking.capture", in: context.hosting)
    if !pressedCapture { await shell.stacking.capture() }
    let captured = await wait(attempts: 400) {
      shell.stacking.captured || shell.stacking.failure != nil
    }
    shell.stacking.mode = .zIndex
    await settle(context)
    let fixture = pageURL.host == "127.0.0.1"
    let modal = shell.stacking.slabs.first { $0.name.contains("#modal") }
    let behind = shell.stacking.slabs.first { $0.name.contains("#behind") }
    let faded = shell.stacking.slabs.first { $0.name.contains("#faded") }
    let card = shell.stacking.slabs.first { $0.name.contains("#card") }
    let picked = fixture ? modal : remoteSlab(in: shell)
    if let picked {
      let pressedSlab = ShaarDevToolsSmokeAccess.press(
        identifier: "shaar.devtools.stacking.slab.\(picked.nodeID)", in: context.hosting)
      if !pressedSlab { shell.stacking.select(picked.nodeID) }
    }
    let selected = await wait(attempts: 120) {
      guard let picked else { return false }
      return sameElement(picked, in: shell)
    }
    let screenshot = outputURL.deletingLastPathComponent().appending(path: "stacking.png")
    let wroteShot = ShaarDevToolsSmokeAccess.capture(context.hosting, to: screenshot)
    let showed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.stacking.showElements", in: context.hosting)
    if !showed, selected { shell.section = .elements }
    await settle(context)
    let elementID = shell.dom.selected?.attributes.first { $0.name == "id" }?.value
    let hidden =
      host.contexts.values.allSatisfy { !$0.window.isVisible }
      && NSApp.windows.allSatisfy { !$0.isVisible }
    let crashes = crashNames().subtracting(crashesBefore).sorted()
    let bundle = Bundle.main.bundleIdentifier ?? ""
    let bundleOK =
      bundle == "com.arcusis.browser"
      || bundle == "com.arcusis.browser.engine-preview"
    let fixtureOK =
      !fixture
      || (modal?.zIndex == 10 && modal?.createsContext == true && behind?.zIndex == -1
        && (behind?.level ?? 0) < (modal?.level ?? 0) && faded?.createsContext == true
        && card?.createsContext == false && elementID == "modal")
    let remoteOK = fixture || !shell.stacking.slabs.isEmpty
    let passed =
      captured && domReady && selected && fixtureOK && remoteOK && shell.section == .elements
      && wroteShot && hidden && crashes.isEmpty && shell.stacking.failure == nil && bundleOK
    write(
      [
        "passed": passed,
        "domReady": domReady,
        "captured": shell.stacking.captured,
        "failure": shell.stacking.failure ?? "",
        "slabCount": shell.stacking.slabs.count,
        "modalZ": modal?.zIndex ?? 0,
        "modalContext": modal?.createsContext ?? false,
        "behindZ": behind?.zIndex ?? 0,
        "behindBelowModal": (behind?.level ?? 0) < (modal?.level ?? 0),
        "fadedContext": faded?.createsContext ?? false,
        "cardContext": card?.createsContext ?? false,
        "selectedInElements": selected,
        "elementID": elementID ?? "",
        "section": shell.section.rawValue,
        "screenshot": wroteShot,
        "allWindowsHidden": hidden,
        "normalBundle": bundle,
        "newCrashReports": crashes,
        "targetURL": target.url.absoluteString,
      ], to: outputURL)
  }

  private static func allows(_ pageURL: URL) -> Bool {
    if pageURL.scheme == "http" { return pageURL.host == "127.0.0.1" }
    return pageURL.scheme == "https" && pageURL.host?.isEmpty == false
  }

  private static func sameElement(_ picked: ShaarStackingSlab, in shell: ShaarDevToolsModel)
    -> Bool
  {
    guard shell.stacking.highlightedID == picked.nodeID, let selectedID = shell.dom.selectedID,
      let node = shell.dom.nodes[selectedID]
    else { return false }
    if selectedID == picked.nodeID { return true }
    guard
      let backend = shell.stacking.elements.first(where: { $0.nodeID == picked.nodeID })?
        .backendNodeID
    else { return false }
    return node.backendNodeID == backend
  }

  private static func remoteSlab(in shell: ShaarDevToolsModel) -> ShaarStackingSlab? {
    if let context = shell.stacking.contexts.first(where: { $0.name != "html" && $0.name != "body" }
    ) {
      return context
    }
    return shell.stacking.contexts.first ?? shell.stacking.slabs.first
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget else { return false }
    guard context.engine.pages[target.tabID]?.loading == false else { return false }
    if pageURL.host == "127.0.0.1" {
      return target.url.host == pageURL.host && target.url.port == pageURL.port
        && target.url.path == pageURL.path
    }
    return target.url.host == pageURL.host
  }

  private static func settle(_ context: NativeBrowserContext) async {
    context.hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    context.hosting.layoutSubtreeIfNeeded()
  }

  private static func wait(attempts: Int, until ready: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if ready() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return ready()
  }

  private static func crashNames() -> Set<String> {
    let directory = URL(fileURLWithPath: NSHomeDirectory())
      .appending(path: "Library/Logs/DiagnosticReports")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return Set(
      names.filter { name in
        let lowered = name.lowercased()
        let relevant =
          lowered.contains("arcusis") || lowered.contains("shaar")
          || lowered.contains("chromium")
        let report = lowered.hasSuffix(".ips") || lowered.hasSuffix(".crash")
        return relevant && report
      })
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}
