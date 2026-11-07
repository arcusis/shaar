// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Replays one click on a hidden localhost page and checks that the page recorded it.
@MainActor enum ShaarRecorderProbe {
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
      write(
        ["error": "No committed web page", "allWindowsHidden": windowsHidden(host)], to: outputURL)
      return
    }
    let windowID = context.engine.windowID
    let click = ShaarDevToolsRecorderStep(
      id: UUID(), kind: .click, selector: "#shaar-flow-target", value: "")
    let installed = await evaluate(
      ShaarDevToolsRecorder.installSource, on: target, runtime: runtime, windowID: windowID)
    let replayed = await evaluate(
      ShaarDevToolsRecorder.replaySource([click]), on: target, runtime: runtime, windowID: windowID)
    let seen = await evaluate(
      "window.__shaarFlowSeen", on: target, runtime: runtime, windowID: windowID)
    let drained = await evaluate(
      ShaarDevToolsRecorder.drainSource, on: target, runtime: runtime, windowID: windowID)
    let recorded = ShaarDevToolsRecorder.steps(from: drained.value).contains { step in
      step.kind == .click && step.selector == "#shaar-flow-target"
    }
    write(
      [
        "error": "",
        "installed": installed.error.isEmpty,
        "replayed": replayed.error.isEmpty,
        "pageRecordedClick": strings(from: seen.value).contains("clicked"),
        "recorderSawClick": recorded,
        "seen": strings(from: seen.value),
        "installError": installed.error,
        "replayError": replayed.error,
        "allWindowsHidden": windowsHidden(host),
        "targetURL": target.url.absoluteString,
      ], to: outputURL)
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget, target.url == pageURL else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    host.contexts.values.allSatisfy { !$0.window.isVisible }
  }

  private static func evaluate(
    _ expression: String, on target: SiteControlTarget, runtime: ARCShaarRuntime, windowID: String
  ) async -> ProbeValue {
    do {
      let result = try await runtime.developerCall(
        "Runtime.evaluate",
        params: ["expression": expression, "returnByValue": true, "awaitPromise": true],
        tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: windowID)
      if let exception = result["exceptionDetails"] as? [String: Any] {
        let text = exception["text"] as? String ?? "page script failed"
        return ProbeValue(value: nil, error: text)
      }
      return ProbeValue(value: (result["result"] as? [String: Any])?["value"], error: "")
    } catch {
      return ProbeValue(value: nil, error: error.localizedDescription)
    }
  }

  private static func strings(from value: Any?) -> [String] {
    if let values = value as? [String] { return values }
    guard let values = value as? [Any] else { return [] }
    return values.compactMap { $0 as? String }
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}

private struct ProbeValue {
  var value: Any?
  var error: String
}
