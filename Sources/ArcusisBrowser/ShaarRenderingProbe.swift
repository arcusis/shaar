// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Proves media emulation on the pinned engine from a window that is never ordered
/// on screen. Overlay commands are attempted once and expected to be rejected until
/// the engine build that accepts them.
@MainActor enum ShaarRenderingProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.host == "127.0.0.1", pageURL.scheme == "http" else { return 2 }
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
        Task { await inspect(host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL) }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: false)
        host.detach()
        return code
      }
    } catch {
      write(["error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func inspect(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, outputURL: URL
  ) async {
    defer { host.events.quit() }
    do { try host.restore() } catch {
      write(["error": error.localizedDescription], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["error": "No hidden browser context"], to: outputURL)
      return
    }
    context.store.perform(.open(pageURL))
    for _ in 0..<300 {
      if pageReady(context, pageURL) { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard pageReady(context, pageURL), let target = context.engine.siteControlTarget else {
      let selected = context.engine.siteControlTarget
      let loading = selected.flatMap { context.engine.pages[$0.tabID]?.loading }
      write(
        [
          "error": "No committed web page",
          "targetURL": selected?.url.absoluteString ?? "",
          "pageLoading": loading ?? true,
          "pageCount": context.engine.pages.count,
          "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
        ], to: outputURL)
      return
    }
    let transport = ShaarRenderingNativeTransport(
      runtime: runtime, windowID: context.engine.windowID, contextID: nil)
    var report: [String: Any] = [
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
      "targetURL": target.url.absoluteString,
    ]
    let applied = ShaarRenderingCommands.calls(
      colorScheme: .dark, motion: .reduce, cssMedia: .print,
      paintRects: false, layoutShiftRegions: false, fpsMeter: false,
      overlayAvailable: false)
    do {
      try await transport.send(applied, to: target)
      report["applied"] = try await mediaFlags(on: target, runtime: runtime, windowID: context.engine.windowID)
    } catch {
      report["applyError"] = error.localizedDescription
    }
    do {
      try await transport.send([ShaarRenderingCall(payload: .paintRects(false))], to: target)
      report["overlayError"] = ""
      report["overlayMissing"] = false
    } catch {
      report["overlayError"] = error.localizedDescription
      report["overlayMissing"] = ShaarRenderingCapability.isMissing(error)
    }
    let cleared = ShaarRenderingCommands.calls(
      colorScheme: .noOverride, motion: .noOverride, cssMedia: .noEmulation,
      paintRects: false, layoutShiftRegions: false, fpsMeter: false,
      overlayAvailable: false)
    do {
      try await transport.send(cleared, to: target)
      report["cleared"] = try await mediaFlags(on: target, runtime: runtime, windowID: context.engine.windowID)
    } catch {
      report["clearError"] = error.localizedDescription
    }
    report["allWindowsHidden"] = host.contexts.values.allSatisfy { !$0.window.isVisible }
    write(report, to: outputURL)
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget, target.url == pageURL else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func mediaFlags(
    on target: SiteControlTarget, runtime: ARCShaarRuntime, windowID: String
  ) async throws -> [String: Bool] {
    let result = try await runtime.developerCall(
      "Runtime.evaluate",
      params: [
        "expression": mediaExpression, "returnByValue": true, "awaitPromise": true,
      ],
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: windowID)
    guard let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] else {
      throw ShaarRenderingFailure("Media query result was missing.")
    }
    var flags: [String: Bool] = [:]
    for key in ["dark", "light", "reduce", "print", "screen"] {
      guard let flag = value[key] as? Bool else {
        throw ShaarRenderingFailure("Media query result was missing \(key).")
      }
      flags[key] = flag
    }
    return flags
  }

  private static let mediaExpression = """
    ({
      dark: matchMedia("(prefers-color-scheme: dark)").matches,
      light: matchMedia("(prefers-color-scheme: light)").matches,
      reduce: matchMedia("(prefers-reduced-motion: reduce)").matches,
      print: matchMedia("print").matches,
      screen: matchMedia("screen").matches
    })
    """

  private static func write(_ report: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}
