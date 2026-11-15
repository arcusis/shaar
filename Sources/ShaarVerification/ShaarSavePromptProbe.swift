// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

@MainActor
final class ShaarSavePromptRenderSurface {
  private let window: NSWindow
  private let previousAlphaValue: CGFloat
  private let previouslyIgnoredMouseEvents: Bool
  private var finished = false

  init(window: NSWindow) {
    self.window = window
    previousAlphaValue = window.alphaValue
    previouslyIgnoredMouseEvents = window.ignoresMouseEvents
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    // orderFront does not activate the app or make the browser window key.
    window.orderFront(nil)
  }

  var isPresentingFramesWithoutInputOrFocus: Bool {
    window.isVisible && window.alphaValue == 0 && window.ignoresMouseEvents
      && !window.isKeyWindow
  }

  @discardableResult
  func orderOutAndRestore() -> Bool {
    guard !finished else { return !window.isVisible }
    finished = true
    window.orderOut(nil)
    window.alphaValue = previousAlphaValue
    window.ignoresMouseEvents = previouslyIgnoredMouseEvents
    return !window.isVisible
  }
}

/// Hidden verification check for Chromium save offers.
@MainActor enum ShaarSavePromptProbe {
  static func run(
    frameworkURL: URL, outputURL: URL, pageURL: URL?, neverPageURL: URL?
  ) -> Int32 {
    guard isLoopbackPage(pageURL), isLoopbackPage(neverPageURL),
      let pageURL, let neverPageURL
    else { return 2 }
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
        Task {
          await exercise(
            host: host, runtime: runtime, base: pageURL, neverBase: neverPageURL,
            outputURL: outputURL)
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

  private static func isLoopbackPage(_ url: URL?) -> Bool {
    url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port != nil
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, base: URL, neverBase: URL,
    outputURL: URL
  ) async {
    var rows: [[String: Any]] = []
    defer {
      hideWindows()
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let onScreen = windowsOnScreen()
      let surfacePresentedSafely = rows.count == 4
        && rows.allSatisfy { $0["renderSurfacePresentedSafely"] as? Bool == true }
      let surfaceOrderedOut = rows.count == 4
        && rows.allSatisfy { $0["renderSurfaceOrderedOut"] as? Bool == true }
      let passed =
        rows.count == 4 && rows.allSatisfy { $0["passed"] as? Bool == true }
        && surfacePresentedSafely && surfaceOrderedOut && hidden && !onScreen
      write(
        [
          "passed": passed, "rows": rows, "allWindowsHidden": hidden,
          "windowsOnScreen": onScreen,
          "renderSurface": [
            "presentedSafely": surfacePresentedSafely, "orderedOut": surfaceOrderedOut,
          ],
        ],
        to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      rows.append(
        await password(context: context, runtime: runtime, base: base, outputURL: outputURL))
      let cardContext = try freshContext(host: host, from: context)
      rows.append(
        await offer(
          name: "card", kind: .card, path: "/card", decision: .save,
          context: cardContext, runtime: runtime, base: base, outputURL: outputURL))
      let addressContext = try freshContext(host: host, from: context)
      rows.append(
        await offer(
          name: "address", kind: .address, path: "/address", decision: .dismiss,
          context: addressContext, runtime: runtime, base: base, outputURL: outputURL))
      let neverContext = try freshContext(host: host, from: context)
      rows.append(
        await neverPassword(context: neverContext, runtime: runtime, base: neverBase))
    } catch {
      rows.append(["name": "setup", "passed": false, "detail": error.localizedDescription])
    }
  }

  private static func freshContext(
    host: NativeBrowserHost, from source: NativeBrowserContext
  ) throws -> NativeBrowserContext {
    let id = try host.newWindow(from: source.id)
    guard let context = host.contexts[id] else { throw Failure("No fresh hidden window") }
    return context
  }

  private static func password(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL, outputURL: URL
  ) async -> [String: Any] {
    let opened = await open(base.appending(path: "password"), context: context)
    hideWindows()
    let renderSurface = opened ? ShaarSavePromptRenderSurface(window: context.window) : nil
    let surfacePresentedSafely =
      renderSurface?.isPresentingFramesWithoutInputOrFocus == true
    let valuesEntered = opened
      ? await trustedText(
        [("username", "parity-user"), ("password", "parity-secret")],
        context: context, runtime: runtime)
      : false
    let clicked = valuesEntered ? await trustedClick(context: context, runtime: runtime) : false
    let prompt = clicked ? await waitForPrompt(in: context, kind: .password) : nil
    let screenshot = prompt != nil && capturePrompt(name: "password", outputURL: outputURL)
    let offscreen = promptPanelIsVisibleOffscreenAndNonKey()
    let saved = prompt != nil && click(ShaarSavePromptPanel.saveIdentifier)
    let cleared = await wait {
      context.store.savePrompt == nil && promptPanel()?.isVisible != true
    }
    let filled = saved ? await filledLogin(context: context, base: base) : (false, false)
    let surfaceOrderedOut = renderSurface?.orderOutAndRestore() ?? false
    hideWindows()
    let passed =
      opened && valuesEntered && clicked && prompt != nil && offscreen && saved && cleared
      && filled.0 && filled.1 && screenshot && surfacePresentedSafely && surfaceOrderedOut
    return [
      "name": "password", "passed": passed, "opened": opened,
      "valuesEntered": valuesEntered,
      "clicked": clicked,
      "prompt": prompt != nil, "offscreen": offscreen, "saved": saved, "cleared": cleared,
      "filledUsername": filled.0, "filledPassword": filled.1, "screenshot": screenshot,
      "renderSurfacePresentedSafely": surfacePresentedSafely,
      "renderSurfaceOrderedOut": surfaceOrderedOut,
    ]
  }

  private static func offer(
    name: String, kind: SavePromptRequest.Kind, path: String,
    decision: SavePromptRequest.Decision, context: NativeBrowserContext,
    runtime: ARCShaarRuntime, base: URL, outputURL: URL
  ) async -> [String: Any] {
    let opened = await open(base.appending(path: path), context: context)
    hideWindows()
    let renderSurface = opened ? ShaarSavePromptRenderSurface(window: context.window) : nil
    let surfacePresentedSafely =
      renderSurface?.isPresentingFramesWithoutInputOrFocus == true
    let fields: [(String, String)] = name == "card"
      ? [("card-name", "Parity Probe"), ("card-number", "4111111111111111"),
         ("card-exp-month", "12"), ("card-exp-year", "2030")]
      : [("address-name", "Parity Probe"), ("address-street", "1 Loopback Road"),
         ("address-city", "Mountain View"), ("address-region", "CA"),
         ("address-postal", "94043"), ("address-country", "US"),
         ("address-email", "parity@example.com")]
    let valuesEntered = opened
      ? await trustedText(fields, context: context, runtime: runtime) : false
    let clicked = valuesEntered
      ? await trustedClick(context: context, runtime: runtime) : false
    let prompt = clicked ? await waitForPrompt(in: context, kind: kind) : nil
    let screenshot = prompt?.kind == kind && capturePrompt(name: name, outputURL: outputURL)
    let offscreen = promptPanelIsVisibleOffscreenAndNonKey()
    let identifier: String
    switch decision {
    case .save: identifier = ShaarSavePromptPanel.saveIdentifier
    case .dismiss: identifier = ShaarSavePromptPanel.dismissIdentifier
    case .never: identifier = ShaarSavePromptPanel.neverIdentifier
    }
    let actionSent = prompt != nil && click(identifier)
    let cleared = await wait {
      context.store.savePrompt == nil && promptPanel()?.isVisible != true
    }
    let surfaceOrderedOut = renderSurface?.orderOutAndRestore() ?? false
    hideWindows()
    let passed =
      opened && valuesEntered && clicked && prompt?.kind == kind && offscreen && actionSent && cleared
      && screenshot && surfacePresentedSafely && surfaceOrderedOut
    return [
      "name": name, "passed": passed, "opened": opened,
      "valuesEntered": valuesEntered,
      "clicked": clicked,
      "prompt": prompt?.kind.rawValue ?? "", "offscreen": offscreen,
      "decision": decision.rawValue, "decisionSent": actionSent,
      "saved": actionSent && decision == .save,
      "cleared": cleared, "screenshot": screenshot,
      "renderSurfacePresentedSafely": surfacePresentedSafely,
      "renderSurfaceOrderedOut": surfaceOrderedOut,
    ]
  }

  private static func neverPassword(
    context: NativeBrowserContext, runtime: ARCShaarRuntime, base: URL
  ) async -> [String: Any] {
    let page = base.appending(path: "password")
    let opened = await open(page, context: context)
    hideWindows()
    let firstSurface = opened ? ShaarSavePromptRenderSurface(window: context.window) : nil
    let firstSurfacePresentedSafely =
      firstSurface?.isPresentingFramesWithoutInputOrFocus == true
    let valuesEntered = opened
      ? await trustedText(
        [("username", "never-user"), ("password", "never-secret")],
        context: context, runtime: runtime)
      : false
    let clicked = valuesEntered ? await trustedClick(context: context, runtime: runtime) : false
    let prompt = clicked ? await waitForPrompt(in: context, kind: .password) : nil
    let visibleOffscreen = prompt != nil && promptPanelIsVisibleOffscreenAndNonKey()
    let neverClicked = prompt != nil && click(ShaarSavePromptPanel.neverIdentifier)
    let cleared = await wait {
      context.store.savePrompt == nil && promptPanel()?.isVisible != true
    }
    let firstSurfaceOrderedOut = firstSurface?.orderOutAndRestore() ?? false
    hideWindows()
    let reopened = await open(page, context: context)
    hideWindows()
    let secondSurface = reopened ? ShaarSavePromptRenderSurface(window: context.window) : nil
    let secondSurfacePresentedSafely =
      secondSurface?.isPresentingFramesWithoutInputOrFocus == true
    let resubmittedValuesEntered = reopened
      ? await trustedText(
        [("username", "never-user"), ("password", "never-secret")],
        context: context, runtime: runtime)
      : false
    let resubmitted = resubmittedValuesEntered
      ? await trustedClick(context: context, runtime: runtime) : false
    let suppressed = resubmitted
      ? await waitForNoPrompt(in: context, duration: .seconds(2)) : false
    let secondSurfaceOrderedOut = secondSurface?.orderOutAndRestore() ?? false
    hideWindows()
    let surfacePresentedSafely = firstSurfacePresentedSafely && secondSurfacePresentedSafely
    let surfaceOrderedOut = firstSurfaceOrderedOut && secondSurfaceOrderedOut
    return [
      "name": "password-never", "passed": opened && valuesEntered && clicked
        && visibleOffscreen && neverClicked && cleared && reopened
        && resubmittedValuesEntered && resubmitted && suppressed
        && surfacePresentedSafely && surfaceOrderedOut,
      "opened": opened, "valuesEntered": valuesEntered,
      "clicked": clicked, "prompt": prompt != nil,
      "visibleOffscreen": visibleOffscreen, "never": neverClicked,
      "cleared": cleared, "reopened": reopened,
      "resubmittedValuesEntered": resubmittedValuesEntered,
      "resubmitted": resubmitted, "suppressed": suppressed,
      "renderSurfacePresentedSafely": surfacePresentedSafely,
      "renderSurfaceOrderedOut": surfaceOrderedOut,
    ]
  }

  private static func waitForNoPrompt(
    in context: NativeBrowserContext, duration: Duration
  ) async -> Bool {
    let iterations = max(1, Int(duration.components.seconds * 10))
    for _ in 0..<iterations {
      if context.store.savePrompt != nil || promptPanel()?.isVisible == true {
        if promptPanel()?.isVisible == true { _ = click(ShaarSavePromptPanel.dismissIdentifier) }
        return false
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return context.store.savePrompt == nil && promptPanel()?.isVisible != true
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
      runtime.submitTrustedProbeClick(inTabID: tab.uuidString, elementID: "plain") {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func trustedText(
    _ fields: [(String, String)], context: NativeBrowserContext, runtime: ARCShaarRuntime
  ) async -> Bool {
    guard let tab = context.engine.siteControlTarget?.tabID else { return false }
    for (elementID, text) in fields {
      let accepted = await withCheckedContinuation { continuation in
        runtime.submitTrustedProbeText(
          inTabID: tab.uuidString, elementID: elementID, text: text)
        { continuation.resume(returning: $0) }
      }
      if !accepted { return false }
    }
    let expected = Dictionary(uniqueKeysWithValues: fields)
    guard let data = try? JSONSerialization.data(withJSONObject: expected),
      let json = String(data: data, encoding: .utf8)
    else { return false }
    let script =
      "(()=>{const expected=\(json);return {valuesEntered:Object.entries(expected).every(([id,value])=>document.getElementById(id)?.value===value)}})()"
    for _ in 0..<20 {
      let verification = await evaluate(context.engine.runtime, tab: tab, script: script)
      if verification?["valuesEntered"] as? Bool == true { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private static func waitForPrompt(
    in context: NativeBrowserContext, kind: SavePromptRequest.Kind
  ) async -> SavePromptRequest? {
    let appeared = await wait {
      context.store.savePrompt?.kind == kind && promptPanel()?.isVisible == true
    }
    if appeared { try? await Task.sleep(for: .milliseconds(500)) }
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

  private static func capturePrompt(name: String, outputURL: URL) -> Bool {
    guard let view = promptPanel()?.contentView, view.bounds.width > 0, view.bounds.height > 0,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
        pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    do {
      try png.write(
        to: outputURL.deletingLastPathComponent().appending(path: "save-prompt-\(name).png"),
        options: .atomic)
      return true
    } catch { return false }
  }

  private static func promptPanelIsVisibleOffscreenAndNonKey() -> Bool {
    guard let panel = promptPanel(), panel.isVisible, !panel.isKeyWindow else { return false }
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
