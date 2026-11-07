// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Proves timezone, locale, and idle overrides from a window that is never ordered
/// on screen. Idle commands are expected to be rejected until the engine build.
@MainActor enum ShaarSensorsProbe {
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
    let windowID = context.engine.windowID
    var report: [String: Any] = [
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
      "targetURL": target.url.absoluteString,
    ]
    report["systemTimezone"] = await reading(
      timeZoneExpression, on: target, runtime: runtime, windowID: windowID)
    report["systemLocale"] = await reading(
      localeExpression, on: target, runtime: runtime, windowID: windowID)
    report["tokyoError"] = await attempt(
      "Emulation.setTimezoneOverride", params: ["timezoneId": "Asia/Tokyo"],
      on: target, runtime: runtime, windowID: windowID)
    report["tokyoTimezone"] = await reading(
      timeZoneExpression, on: target, runtime: runtime, windowID: windowID)
    report["emptyTimezoneError"] = await attempt(
      "Emulation.setTimezoneOverride", params: ["timezoneId": ""],
      on: target, runtime: runtime, windowID: windowID)
    report["emptyTimezoneZone"] = await reading(
      timeZoneExpression, on: target, runtime: runtime, windowID: windowID)
    report["frenchError"] = await attempt(
      "Emulation.setLocaleOverride", params: ["locale": "fr-FR"],
      on: target, runtime: runtime, windowID: windowID)
    report["frenchLocale"] = await reading(
      localeExpression, on: target, runtime: runtime, windowID: windowID)
    report["emptyLocaleError"] = await attempt(
      "Emulation.setLocaleOverride", params: ["locale": ""],
      on: target, runtime: runtime, windowID: windowID)
    report["emptyLocaleValue"] = await reading(
      localeExpression, on: target, runtime: runtime, windowID: windowID)
    let idleError = await attempt(
      "Emulation.clearIdleOverride", params: [:], on: target, runtime: runtime, windowID: windowID)
    report["idleError"] = idleError
    report["idleMissing"] = idleRejected(idleError)
    report["allWindowsHidden"] = host.contexts.values.allSatisfy { !$0.window.isVisible }
    write(report, to: outputURL)
  }

  private static let timeZoneExpression = "Intl.DateTimeFormat().resolvedOptions().timeZone"
  private static let localeExpression = "Intl.DateTimeFormat().resolvedOptions().locale"

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget, target.url == pageURL else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func idleRejected(_ message: String) -> Bool {
    if message.isEmpty { return false }
    return ShaarDevToolsSensorCapability.isMissing(ProbeError(message))
  }

  private static func attempt(
    _ method: String, params: [String: Any], on target: SiteControlTarget,
    runtime: ARCShaarRuntime, windowID: String
  ) async -> String {
    do {
      _ = try await runtime.developerCall(
        method, params: params, tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID)
      return ""
    } catch {
      return error.localizedDescription
    }
  }

  private static func reading(
    _ expression: String, on target: SiteControlTarget, runtime: ARCShaarRuntime, windowID: String
  ) async -> String {
    do {
      let result = try await runtime.developerCall(
        "Runtime.evaluate",
        params: ["expression": expression, "returnByValue": true],
        tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: windowID)
      return ((result["result"] as? [String: Any])?["value"] as? String) ?? ""
    } catch {
      return ""
    }
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}

private struct ProbeError: LocalizedError {
  var errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
