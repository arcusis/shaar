// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Hidden shipping proof that F12 and Option-Command-I open the Chromium dock.
@MainActor enum ShaarDevToolsF12RouteSmoke {
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
      let passed = rows.count == 3 && rows.allSatisfy { $0["passed"] as? Bool == true } && hidden
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
      rows.append(await proveChromiumShortcut(
        name: "f12", context: context, host: host, tab: tab, outputURL: outputURL,
        fire: {
          guard let event = f12Event(in: context.window) else { return false }
          return host.performDeveloperToolsKey(event)
        }))
      rows.append(await proveChromiumShortcut(
        name: "option-command-i", context: context, host: host, tab: tab, outputURL: outputURL,
        fire: { routeOptionCommandI(host: host, window: context.window) }))
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
    await closeChromiumDock(context: context, host: host, tab: tab)
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
    if !fired { row["detail"] = fireDetail(name: name, context: context, host: host) }
    return row
  }

  private static func proveLegacyShell(
    context: NativeBrowserContext, host: NativeBrowserHost, tab: UUID
  ) async -> [String: Any] {
    await closeChromiumDock(context: context, host: host, tab: tab)
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
    return "event=\(event != nil) f12=\(recognized) "
      + "canPerform=\(host.canPerform(command)) command=\(command.rawValue) "
      + "visible=\(context.window.isVisible)"
  }

  private static func closeChromiumDock(
    context: NativeBrowserContext, host: NativeBrowserHost, tab: UUID
  ) async {
    guard chromiumDockIsOpen(context: context, tab: tab) else { return }
    host.perform(.chromiumDeveloperTools)
    _ = await wait { !chromiumDockIsOpen(context: context, tab: tab) }
  }

  private static func chromiumDockIsOpen(context: NativeBrowserContext, tab: UUID) -> Bool {
    context.engine.runtime.devToolsView(forTabID: tab.uuidString) != nil
  }

  private static func routeOptionCommandI(host: NativeBrowserHost, window: NSWindow) -> Bool {
    guard let menu = NSApp.mainMenu, let event = optionCommandIEvent(in: window) else {
      return false
    }
    return ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder)
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
