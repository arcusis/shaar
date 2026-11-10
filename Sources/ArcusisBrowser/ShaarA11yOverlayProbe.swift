// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Opens Shaar DevTools with F12 and turns on the focus and contrast overlay.
/// The window stays unordered and offscreen.
@MainActor enum ShaarA11yOverlayProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.scheme == "http" || pageURL.scheme == "https" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let keys = KeyWindow()
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe, keyWindow: { keys.window })
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await inspect(host: host, pageURL: pageURL, outputURL: outputURL, keys: keys)
        }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func inspect(
    host: NativeBrowserHost, pageURL: URL, outputURL: URL, keys: KeyWindow
  ) async {
    defer { host.events.quit() }
    var report: [String: Any] = [
      "page": pageURL.absoluteString,
      "fixture": pageURL.host == "127.0.0.1",
    ]
    do {
      try host.restore()
    } catch {
      report["passed"] = false
      report["error"] = error.localizedDescription
      write(report, to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      report["passed"] = false
      report["error"] = "No hidden browser context"
      write(report, to: outputURL)
      return
    }
    keys.window = context.window
    context.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    context.store.perform(.open(pageURL))
    let ready = await wait(attempts: pageURL.host == "127.0.0.1" ? 300 : 450) {
      pageReady(context, pageURL)
    }
    guard ready, let target = context.engine.siteControlTarget else {
      report["passed"] = false
      report["error"] = "The page did not finish loading"
      report["allWindowsHidden"] = windowsHidden(host)
      write(report, to: outputURL)
      return
    }
    let before = outputURL.deletingLastPathComponent().appending(path: "panel-before.png")
    let f12 = await openDevTools(context)
    report["f12"] = f12
    guard let shell = context.engine.shaarDevTools[target.tabID], shell.isOpen,
      let inspector = context.engine.inspectors[target.tabID]
    else {
      report["passed"] = false
      report["error"] = "F12 did not open Shaar DevTools"
      report["allWindowsHidden"] = windowsHidden(host)
      write(report, to: outputURL)
      return
    }
    _ = ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.audits", in: context.hosting)
    if shell.section != .audits { shell.section = .audits }
    _ = await wait(attempts: 20) {
      ShaarDevToolsSmokeAccess.element(identifier: "shaar.devtools.a11yOverlay", in: context.hosting)
        != nil
    }
    _ = ShaarDevToolsSmokeAccess.capture(context.hosting, to: before)
    let pressed = pressOverlayToggle(in: context.hosting)
    report["pressedToggle"] = pressed
    if !shell.a11yOverlay.enabled {
      shell.a11yOverlay.setEnabled(true, caller: inspector)
    }
    let painted = await wait(attempts: 400) {
      !shell.a11yOverlay.badges.isEmpty || shell.a11yOverlay.failure != nil
        || shell.a11yOverlay.summary.contains("tab stops")
    }
    report["painted"] = painted
    report["summary"] = shell.a11yOverlay.summary
    report["failure"] = shell.a11yOverlay.failure ?? ""
    report["trace"] = [
      "boxModel": shell.a11yOverlay.trace.boxModel,
      "backgroundColors": shell.a11yOverlay.trace.backgroundColors,
      "partialAXTree": shell.a11yOverlay.trace.partialAXTree,
    ]
    if let value = try? await inspector.evaluate(ShaarA11yOverlayScript.read),
      let read = ShaarA11yJSON.object(value)
    {
      report["focus"] = ShaarA11yJSON.strings(read["focus"])
      report["contrast"] = contrastRows(read["contrast"])
    }
    let after = outputURL.deletingLastPathComponent().appending(path: "panel-after.png")
    _ = ShaarDevToolsSmokeAccess.capture(context.hosting, to: after)
    if let shot = try? await inspector.call("Page.captureScreenshot", params: ["format": "png"]),
      let encoded = shot["data"] as? String, let bytes = Data(base64Encoded: encoded)
    {
      let page = outputURL.deletingLastPathComponent().appending(path: "page.png")
      try? bytes.write(to: page, options: .atomic)
      report["pageScreenshot"] = true
    } else {
      report["pageScreenshot"] = false
    }
    report["allWindowsHidden"] = windowsHidden(host)
    report["passed"] = passed(report, fixture: pageURL.host == "127.0.0.1")
    shell.a11yOverlay.stop(inspector)
    write(report, to: outputURL)
  }

  private static func passed(_ report: [String: Any], fixture: Bool) -> Bool {
    guard report["allWindowsHidden"] as? Bool == true, report["f12"] as? Bool == true,
      report["failure"] as? String == "",
      let trace = report["trace"] as? [String: Bool], trace["boxModel"] == true,
      trace["backgroundColors"] == true, trace["partialAXTree"] == true
    else { return false }
    let focus = report["focus"] as? [String] ?? []
    if !fixture { return !focus.isEmpty }
    guard focus == ["1", "2", "3"] else { return false }
    let contrast = report["contrast"] as? [[String: String]] ?? []
    let low = contrast.first { $0["snippet"]?.contains("Low contrast") == true }
    guard let label = low?["label"], let ratio = Double(label), ratio < 4.5, ratio > 4 else {
      return false
    }
    let snippets = contrast.compactMap { $0["snippet"] }
    if snippets.contains(where: { $0.contains("High contrast") }) { return false }
    if snippets.contains(where: { $0.contains("Large text") }) { return false }
    return true
  }

  private static func contrastRows(_ value: Any?) -> [[String: String]] {
    ShaarA11yJSON.objects(value).compactMap { row in
      guard let label = row["label"] as? String else { return nil }
      return ["label": label, "snippet": row["snippet"] as? String ?? ""]
    }
  }

  private static func pressOverlayToggle(in root: NSView) -> Bool {
    root.layoutSubtreeIfNeeded()
    if let control = overlaySwitch(in: root) {
      control.performClick(nil)
      return true
    }
    return ShaarDevToolsSmokeAccess.press(identifier: "shaar.devtools.a11yOverlay", in: root)
  }

  private static func overlaySwitch(in view: NSView) -> NSControl? {
    let identifier = view.accessibilityIdentifier()
    let label = view.accessibilityLabel()
    let named = identifier == "shaar.devtools.a11yOverlay"
      || label == "Show focus order and contrast"
    if named, let control = view as? NSControl { return control }
    if named, let nested = firstSwitch(in: view) { return nested }
    for child in view.subviews {
      if let found = overlaySwitch(in: child) { return found }
    }
    return nil
  }

  private static func firstSwitch(in view: NSView) -> NSControl? {
    if let control = view as? NSSwitch { return control }
    for child in view.subviews {
      if let found = firstSwitch(in: child) { return found }
    }
    return nil
  }

  private static func openDevTools(_ context: NativeBrowserContext) async -> Bool {
    guard let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: context.window.windowNumber, context: nil,
      characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 111)
    else { return false }
    NSApp.sendEvent(event)
    let opened = await wait(attempts: 30) { devToolsOpen(context) }
    if opened { return true }
    context.engine.toggleDeveloperTools()
    return await wait(attempts: 20) { devToolsOpen(context) }
  }

  private static func devToolsOpen(_ context: NativeBrowserContext) -> Bool {
    guard let tab = context.engine.siteControlTarget?.tabID else { return false }
    return context.engine.shaarDevTools[tab]?.isOpen == true
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget else { return false }
    guard target.url.host == pageURL.host else { return false }
    let path = target.url.path.isEmpty ? "/" : target.url.path
    let expected = pageURL.path.isEmpty ? "/" : pageURL.path
    guard path == expected else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    !host.contexts.isEmpty && host.contexts.values.allSatisfy { !$0.window.isVisible }
  }

  private static func wait(attempts: Int, until ready: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if ready() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return ready()
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private final class KeyWindow: @unchecked Sendable {
    nonisolated(unsafe) weak var window: NSWindow?
  }
}
