// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Hidden shipping check for Chromium save offers. The current engine does not emit them yet,
/// so a missing bubble fails this probe instead of being reported as saved.
@MainActor enum ShaarSavePromptProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.scheme == "http", pageURL.host == "127.0.0.1" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    do {
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
        Task { await exercise(host: host, runtime: runtime, base: pageURL, outputURL: outputURL) }
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
    host: NativeBrowserHost, runtime: ARCShaarRuntime, base: URL, outputURL: URL
  ) async {
    var rows: [[String: Any]] = []
    defer {
      hideWindows()
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let onScreen = windowsOnScreen()
      let passed =
        rows.count == 3 && rows.allSatisfy { $0["passed"] as? Bool == true }
        && hidden && !onScreen
      write(
        ["passed": passed, "rows": rows, "allWindowsHidden": hidden, "windowsOnScreen": onScreen],
        to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      rows.append(await password(context: context, runtime: runtime, base: base))
      hideWindows()
      rows.append(
        await offer(
          name: "card", kind: .card, path: "/card", context: context, runtime: runtime, base: base))
      hideWindows()
      rows.append(
        await offer(
          name: "address", kind: .address, path: "/address", context: context, runtime: runtime,
          base: base))
    } catch {
      rows.append(["name": "setup", "passed": false, "detail": error.localizedDescription])
    }
  }

  private static func password(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL
  ) async -> [String: Any] {
    let opened = await open(base.appending(path: "password"), context: context)
    hideWindows()
    let clicked = opened ? await trustedClick(context: context, runtime: runtime) : false
    let prompt = await waitForPrompt(in: context, kind: .password)
    let offscreen = panelStaysOffscreen()
    let saved = prompt != nil && click(ShaarSavePromptPanel.saveIdentifier)
    let cleared = await wait {
      context.store.savePrompt == nil && promptPanel()?.isVisible != true
    }
    let filled = saved ? await filledLogin(context: context, base: base) : (false, false)
    let passed =
      opened && clicked && prompt != nil && offscreen && saved && cleared
      && filled.0 && filled.1
    return [
      "name": "password", "passed": passed, "opened": opened, "clicked": clicked,
      "prompt": prompt != nil, "offscreen": offscreen, "saved": saved, "cleared": cleared,
      "filledUsername": filled.0, "filledPassword": filled.1,
    ]
  }

  private static func offer(
    name: String, kind: SavePromptRequest.Kind, path: String, context: NativeBrowserContext,
    runtime: ARCShaarRuntime, base: URL
  ) async -> [String: Any] {
    let opened = await open(base.appending(path: path), context: context)
    hideWindows()
    let clicked = opened ? await trustedClick(context: context, runtime: runtime) : false
    let prompt = await waitForPrompt(in: context, kind: kind)
    let offscreen = panelStaysOffscreen()
    let saved = prompt != nil && click(ShaarSavePromptPanel.saveIdentifier)
    let cleared = await wait {
      context.store.savePrompt == nil && promptPanel()?.isVisible != true
    }
    let passed = opened && clicked && prompt?.kind == kind && offscreen && saved && cleared
    return [
      "name": name, "passed": passed, "opened": opened, "clicked": clicked,
      "prompt": prompt?.kind.rawValue ?? "", "offscreen": offscreen, "saved": saved,
      "cleared": cleared,
    ]
  }

  private static func open(_ url: URL, context: NativeBrowserContext) async -> Bool {
    context.store.perform(.open(url))
    return await wait {
      context.engine.siteControlTarget?.url.path == url.path
        && context.engine.siteControlTarget.flatMap { context.engine.pages[$0.tabID] }?.loading
          == false
    }
  }

  private static func trustedClick(
    context: NativeBrowserContext, runtime: ARCShaarRuntime
  ) async -> Bool {
    guard let tab = context.engine.siteControlTarget?.tabID else { return false }
    return await withCheckedContinuation { continuation in
      runtime.submitTrustedProbeClick(inTabID: tab.uuidString, elementID: "parity-action") {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func waitForPrompt(
    in context: NativeBrowserContext, kind: SavePromptRequest.Kind
  ) async -> SavePromptRequest? {
    let appeared = await wait { context.store.savePrompt?.kind == kind }
    return appeared ? context.store.savePrompt : nil
  }

  private static func filledLogin(
    context: NativeBrowserContext, base: URL
  ) async -> (Bool, Bool) {
    let login = base.appending(path: "login")
    guard await open(login, context: context),
      let tab = context.engine.siteControlTarget?.tabID
    else { return (false, false) }
    var username = false
    var password = false
    for _ in 0..<50 {
      let fields = await evaluate(
        context.engine.runtime, tab: tab,
        script:
          "({username:document.getElementById('username')?.value||'',password:document.getElementById('password')?.value||''})"
      )
      username = fields?["username"] as? String == "parity-user"
      password = fields?["password"] as? String == "parity-secret"
      if username && password { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return (username, password)
  }

  private static func click(_ identifier: String) -> Bool {
    guard let button = SavePromptButtons.find(promptPanel()?.contentView, identifier: identifier),
      button.isEnabled
    else { return false }
    button.performClick(nil)
    return true
  }

  private static func promptPanel() -> ShaarSavePromptPanel? {
    NSApp.windows.compactMap { $0 as? ShaarSavePromptPanel }.first
  }

  private static func panelStaysOffscreen() -> Bool {
    guard let panel = promptPanel(), panel.isVisible else { return true }
    return !NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
  }

  private static func windowsOnScreen() -> Bool {
    NSApp.windows.contains { window in
      window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }
  }

  private static func hideWindows() {
    for window in NSApp.windows where window.isVisible {
      window.orderOut(nil)
    }
  }

  private static func evaluate(
    _ runtime: ARCChromiumRuntime, tab: UUID, script: String
  ) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
