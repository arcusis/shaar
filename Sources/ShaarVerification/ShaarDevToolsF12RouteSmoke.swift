// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

/// Hidden verification proof that F12 and Option-Command-I open the Chromium dock.
@MainActor enum ShaarDevToolsF12RouteSmoke {
  static func run(arguments: [String]) -> Int32 {
    guard let index = arguments.firstIndex(of: "--devtools-f12-route"),
      arguments.indices.contains(index + 2),
      let frameworks = Bundle.main.privateFrameworksURL
    else { return 2 }
    let framework = frameworks.appending(path: "Chromium Framework.framework")
    let output = URL(fileURLWithPath: arguments[index + 1])
    return run(
      frameworkURL: framework, outputURL: output, pageURL: URL(string: arguments[index + 2]))
  }

  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.scheme == "http", pageURL.host == "127.0.0.1" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let probeKey = ProbeKeyWindow()
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe, keyWindow: { probeKey.window })
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await exercise(
            host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL,
            probeKey: probeKey)
        }
      }
      return withExtendedLifetime(host) {
        let dataRoot = outputURL.deletingLastPathComponent().appending(path: "Chromium")
        let code = runtime.run(withDataDirectory: dataRoot, testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCChromiumRuntime, pageURL: URL, outputURL: URL,
    probeKey: ProbeKeyWindow
  ) async {
    var rows: [[String: Any]] = []
    defer {
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let passed = rows.count == 4 && rows.allSatisfy { $0["passed"] as? Bool == true } && hidden
      write(
        ["passed": passed, "rows": rows, "allWindowsHidden": hidden],
        to: outputURL)
      host.events.quit()
    }
    let defaultsKey = ShaarDevToolsRoute.legacyShellDefaultsKey
    let previousDefault = UserDefaults.standard.object(forKey: defaultsKey)
    defer { restoreDefault(defaultsKey, previous: previousDefault) }
    UserDefaults.standard.removeObject(forKey: defaultsKey)
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      context.store.perform(.open(pageURL))
      let ready = await wait {
        guard let target = context.engine.siteControlTarget, target.url == pageURL else {
          return false
        }
        return context.engine.pages[target.tabID]?.loading == false
          && context.engine.runtime.view(forTabID: target.tabID.uuidString)?.superview != nil
      }
      guard ready, let tab = context.engine.siteControlTarget?.tabID else {
        throw Failure("Fixture page did not load")
      }
      probeKey.window = context.window
      if context.window.isVisible { context.window.orderOut(nil) }
      closeLegacyShell(context: context, tab: tab)
      rows.append(
        await proveChromiumShortcut(
          name: "f12", context: context, host: host, tab: tab, outputURL: outputURL,
          fire: {
            guard let event = f12Event(in: context.window) else { return false }
            return host.performDeveloperToolsKey(event)
          }))
      rows.append(
        await proveChromiumShortcut(
          name: "option-command-i", context: context, host: host, tab: tab, outputURL: outputURL,
          fire: { routeOptionCommandI(host: host, window: context.window) }))
      rows.append(await proveF12ClosesOpenShell(context: context, host: host, tab: tab))
      UserDefaults.standard.set(true, forKey: ShaarDevToolsRoute.legacyShellDefaultsKey)
      rows.append(await proveLegacyShell(context: context, host: host, tab: tab))
    } catch {
      rows.append(["name": "setup", "passed": false, "detail": error.localizedDescription])
    }
  }

  private static func restoreDefault(_ key: String, previous: Any?) {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private static func closeLegacyShell(context: NativeBrowserContext, tab: UUID) {
    guard context.engine.shaarDevTools[tab]?.isOpen == true else { return }
    context.engine.toggleDeveloperTools()
  }

  private static func proveChromiumShortcut(
    name: String, context: NativeBrowserContext, host: NativeBrowserHost, tab: UUID,
    outputURL: URL, fire: () -> Bool
  ) async -> [String: Any] {
    if let detail = await closeChromiumDock(context: context, tab: tab) {
      return [
        "name": name, "passed": false, "detail": detail, "fired": false,
        "notice": context.engine.notice ?? "",
      ]
    }
    closeLegacyShell(context: context, tab: tab)
    let shellBefore = context.engine.shaarDevTools[tab]?.isOpen == true
    let fired = fire()
    if context.window.isVisible { context.window.orderOut(nil) }
    let opened = await wait {
      chromiumDockIsOpen(context: context, tab: tab)
        && context.engine.shaarDevTools[tab]?.isOpen != true
    }
    let shot = snapshot(context: context, tab: tab, name: name, outputURL: outputURL)
    let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
    let passed = fired && opened && !shellBefore && hidden
    var row: [String: Any] = [
      "name": name, "passed": passed, "fired": fired, "chromiumDock": opened,
      "legacyShell": context.engine.shaarDevTools[tab]?.isOpen == true,
      "windowsHidden": hidden, "snapshot": shot,
      "notice": context.engine.notice ?? "",
    ]
    if !passed {
      row["detail"] = fireDetail(name: name, context: context, host: host)
      if let open = await engineDevToolsOpen(context.engine.runtime, tab: tab) {
        row["engineOpen"] = open
      }
    }
    return row
  }

  private static func proveF12ClosesOpenShell(
    context: NativeBrowserContext, host: NativeBrowserHost, tab: UUID
  ) async -> [String: Any] {
    if let detail = await closeChromiumDock(context: context, tab: tab) {
      return ["name": "f12-closes-legacy-shell", "passed": false, "detail": detail]
    }
    guard let target = context.engine.siteControlTarget, target.tabID == tab else {
      return ["name": "f12-closes-legacy-shell", "passed": false, "detail": "No page target"]
    }
    let shown = context.engine.showDeveloperTools(for: target)
    let shellBefore = context.engine.shaarDevTools[tab]?.isOpen == true
    guard let event = f12Event(in: context.window) else {
      return [
        "name": "f12-closes-legacy-shell", "passed": false,
        "detail": "Could not build an F12 event",
      ]
    }
    let fired = host.performDeveloperToolsKey(event)
    if context.window.isVisible { context.window.orderOut(nil) }
    let settled = await wait {
      context.engine.shaarDevTools[tab]?.isOpen != true
        && chromiumDockIsOpen(context: context, tab: tab)
    }
    let shellClosed = context.engine.shaarDevTools[tab]?.isOpen != true
    let dockOpen = chromiumDockIsOpen(context: context, tab: tab)
    let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
    return [
      "name": "f12-closes-legacy-shell",
      "passed": shown && shellBefore && fired && settled && hidden,
      "fired": fired, "legacyShell": !shellClosed, "chromiumDock": dockOpen,
      "windowsHidden": hidden, "notice": context.engine.notice ?? "",
    ]
  }

  private static func proveLegacyShell(
    context: NativeBrowserContext, host: NativeBrowserHost, tab: UUID
  ) async -> [String: Any] {
    if let detail = await closeChromiumDock(context: context, tab: tab) {
      return ["name": "legacy-shell", "passed": false, "detail": detail]
    }
    guard let event = f12Event(in: context.window) else {
      return ["name": "legacy-shell", "passed": false, "detail": "Could not build an F12 event"]
    }
    let fired = host.performDeveloperToolsKey(event)
    if context.window.isVisible { context.window.orderOut(nil) }
    let shell = await wait { context.engine.shaarDevTools[tab]?.isOpen == true }
    try? await Task.sleep(for: .milliseconds(400))
    let chromiumClosed = !chromiumDockIsOpen(context: context, tab: tab)
    let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
    var row: [String: Any] = [
      "name": "legacy-shell", "passed": fired && shell && chromiumClosed && hidden,
      "fired": fired, "legacyShell": shell, "chromiumDock": !chromiumClosed,
      "windowsHidden": hidden, "notice": context.engine.notice ?? "",
    ]
    if !fired { row["detail"] = fireDetail(name: "legacy-shell", context: context, host: host) }
    return row
  }

  private static func fireDetail(
    name: String, context: NativeBrowserContext, host: NativeBrowserHost
  ) -> String {
    let event: NSEvent?
    if name == "option-command-i" {
      event = optionCommandIEvent(in: context.window)
    } else {
      event = f12Event(in: context.window)
    }
    let command = ShaarDevToolsRoute.f12Command()
    let recognized = event.map(ShaarDevToolsShortcut.isF12) ?? false
    let menuMatches = NSApp.mainMenu === host.menu
    return "event=\(event != nil) f12=\(recognized) "
      + "canPerform=\(host.canPerform(command)) command=\(command.rawValue) "
      + "visible=\(context.window.isVisible) mainMenuMatches=\(menuMatches)"
  }

  /// ClosePage() replies before the DevTools window is gone. The next toggle
  /// still sees that window and closes it, so wait for the engine to report closed.
  private static func closeChromiumDock(context: NativeBrowserContext, tab: UUID) async -> String? {
    let runtime = context.engine.runtime
    guard let open = await engineDevToolsOpen(runtime, tab: tab) else {
      return "DevTools state unavailable"
    }
    if open || chromiumDockIsOpen(context: context, tab: tab) {
      guard runtime.closeDevTools(forTabID: tab.uuidString) else {
        return "DevTools close was rejected"
      }
    }
    for _ in 0..<200 {
      if !chromiumDockIsOpen(context: context, tab: tab),
        await engineDevToolsOpen(runtime, tab: tab) == false
      {
        return nil
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let stillOpen = await engineDevToolsOpen(runtime, tab: tab)
    if stillOpen == false, !chromiumDockIsOpen(context: context, tab: tab) {
      return nil
    }
    return "DevTools stayed open after close"
  }

  private static func engineDevToolsOpen(_ runtime: ARCChromiumRuntime, tab: UUID) async -> Bool? {
    await withCheckedContinuation { continuation in
      runtime.probeDevToolsUIOpen(forTabID: tab.uuidString) { open in
        continuation.resume(returning: open?.boolValue)
      }
    }
  }

  private static func chromiumDockIsOpen(context: NativeBrowserContext, tab: UUID) -> Bool {
    context.engine.runtime.devToolsView(forTabID: tab.uuidString) != nil
  }

  private static func routeOptionCommandI(host: NativeBrowserHost, window: NSWindow) -> Bool {
    guard let menu = host.menu, NSApp.mainMenu === menu, let event = optionCommandIEvent(in: window)
    else { return false }
    if host.performDeveloperToolsKey(event) { return true }
    let responder = event.window?.firstResponder ?? window.firstResponder
    return ShortcutPageRouting.route(event, menu: menu, responder: responder)
  }

  private static func f12Event(in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{F70F}", charactersIgnoringModifiers: "\u{F70F}",
      isARepeat: false, keyCode: 111)
  }

  private static func optionCommandIEvent(in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .option],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "i", charactersIgnoringModifiers: "i",
      isARepeat: false, keyCode: 34)
  }

  private static func snapshot(
    context: NativeBrowserContext, tab: UUID, name: String, outputURL: URL
  ) -> String {
    guard let card = context.engine.runtime.view(forTabID: tab.uuidString),
      card.bounds.width > 1, card.bounds.height > 1,
      let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)
    else { return "" }
    card.cacheDisplay(in: card.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return "" }
    let url = outputURL.deletingLastPathComponent().appending(path: "\(name).png")
    do {
      try data.write(to: url, options: .atomic)
      return url.lastPathComponent
    } catch {
      return ""
    }
  }

  private static func wait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private static func write(_ value: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private final class ProbeKeyWindow {
    var window: NSWindow?
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
