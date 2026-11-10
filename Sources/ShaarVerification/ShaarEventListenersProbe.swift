// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Proves listener inspection from a window that is never ordered on screen.
/// shaar.20 rejects DOMDebugger.getEventListeners and callFunctionOn arguments.
@MainActor enum ShaarEventListenersProbe {
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
        [
          "error": "No committed web page",
          "allWindowsHidden": windowsHidden(host),
        ], to: outputURL)
      return
    }
    var report: [String: Any] = [
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "allWindowsHidden": windowsHidden(host),
      "targetURL": target.url.absoluteString,
    ]
    let enabled = await call(
      "DOM.enable", params: [:], on: target, runtime: runtime, windowID: context.engine.windowID)
    report["domEnableError"] = enabled.error
    let document = await call(
      "DOM.getDocument", params: ["depth": 4, "pierce": false],
      on: target, runtime: runtime, windowID: context.engine.windowID)
    let root = (document.result["root"] as? [String: Any])?["nodeId"]
    report["documentReady"] =
      integer(root) != nil && enabled.error.isEmpty && document.error.isEmpty
    report["documentError"] = document.error
    let search = await call(
      "DOM.performSearch", params: ["query": "#shaar-listener"],
      on: target, runtime: runtime, windowID: context.engine.windowID)
    let searchID = search.result["searchId"] as? String ?? ""
    let count = integer(search.result["resultCount"]) ?? 0
    report["searchCount"] = count
    var nodeID = 0
    if !searchID.isEmpty, count > 0 {
      let results = await call(
        "DOM.getSearchResults",
        params: ["searchId": searchID, "fromIndex": 0, "toIndex": 1],
        on: target, runtime: runtime, windowID: context.engine.windowID)
      nodeID = integer((results.result["nodeIds"] as? [Any])?.first) ?? 0
    }
    var objectID = ""
    if nodeID > 0 {
      let resolved = await call(
        "DOM.resolveNode", params: ["nodeId": nodeID],
        on: target, runtime: runtime, windowID: context.engine.windowID)
      objectID = ((resolved.result["object"] as? [String: Any])?["objectId"] as? String) ?? ""
      report["resolveError"] = resolved.error
    }
    report["nodeResolved"] = !objectID.isEmpty
    let listeners = await call(
      "DOMDebugger.getEventListeners",
      params: ["objectId": objectID.isEmpty ? "missing" : objectID, "depth": 1, "pierce": false],
      on: target, runtime: runtime, windowID: context.engine.windowID)
    report["listenerError"] = listeners.error
    report["listenerMissing"] = rejected(listeners.error)
    report["listenerCount"] = (listeners.result["listeners"] as? [Any])?.count ?? 0
    let arguments = await call(
      "Runtime.callFunctionOn",
      params: [
        "objectId": objectID.isEmpty ? "missing" : objectID,
        "functionDeclaration": "function() { return true; }",
        "returnByValue": true,
        "arguments": [["value": "click"]],
      ],
      on: target, runtime: runtime, windowID: context.engine.windowID)
    report["argumentsError"] = arguments.error
    report["argumentsRejected"] = rejected(arguments.error)
    if !objectID.isEmpty {
      _ = await call(
        "Runtime.releaseObject", params: ["objectId": objectID],
        on: target, runtime: runtime, windowID: context.engine.windowID)
    }
    report["allWindowsHidden"] = windowsHidden(host)
    write(report, to: outputURL)
  }

  private static func pageReady(_ context: NativeBrowserContext, _ pageURL: URL) -> Bool {
    guard let target = context.engine.siteControlTarget, target.url == pageURL else { return false }
    return context.engine.pages[target.tabID]?.loading == false
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    host.contexts.values.allSatisfy { !$0.window.isVisible }
  }

  private static func rejected(_ message: String) -> Bool {
    let folded = message.lowercased()
    if folded.isEmpty { return false }
    if folded.contains("unknown") || folded.contains("unavailable") || folded.contains("failed") {
      return true
    }
    return folded.contains("invalid") || folded.contains("parameter")
  }

  private static func call(
    _ method: String, params: [String: Any], on target: SiteControlTarget,
    runtime: ARCShaarRuntime, windowID: String
  ) async -> (result: [String: Any], error: String) {
    do {
      let result = try await runtime.inspectorCall(
        method, params: params, tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID)
      return (result, "")
    } catch {
      return ([:], error.localizedDescription)
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      return number.intValue
    }
    return nil
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}
