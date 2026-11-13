// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

struct ShaarTabAdoptionEvidence {
  let clicked: Bool
  let adopted: Bool
  let expectedElementID: String
  let clickedElementID: String?
  let trustedGesture: String?
  let destinationMarker: String?
  let destinationHost: String?
  let destinationBelongsToWindow: Bool
  let rendererFailuresAreEmpty: Bool
  let allWindowsHidden: Bool

  var passed: Bool {
    clicked && adopted && clickedElementID == expectedElementID && trustedGesture == "true"
      && destinationMarker == "Cross-site destination loaded"
      && destinationHost == "localhost" && destinationBelongsToWindow
      && rendererFailuresAreEmpty && allWindowsHidden
  }
}

/// Exercises page-created tabs in the hidden verification harness, using native trusted clicks.
@MainActor enum ShaarTabAdoptionSmoke {
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
        Task {
          await exercise(host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL)
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
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, outputURL: URL
  ) async {
    var rows: [[String: Any]] = []
    defer {
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let passed = rows.count == 2 && rows.allSatisfy { $0["passed"] as? Bool == true } && hidden
      write(["passed": passed, "rows": rows, "allWindowsHidden": hidden], to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      for (name, elementID) in [("target=_blank", "blank"), ("window.open", "popup")] {
        let row = await check(
          name: name, elementID: elementID, context: context, host: host,
          runtime: runtime, pageURL: pageURL)
        rows.append(row)
      }
    } catch {
      rows.append(["name": "setup", "passed": false, "detail": error.localizedDescription])
    }
  }

  private static func check(
    name: String, elementID: String, context: NativeBrowserContext, host: NativeBrowserHost,
    runtime: ARCShaarRuntime, pageURL: URL
  ) async -> [String: Any] {
    context.store.perform(.open(pageURL))
    let ready = await wait {
      context.engine.siteControlTarget?.url == pageURL
        && context.engine.siteControlTarget.flatMap { context.engine.pages[$0.tabID] }?.loading
          == false
    }
    guard ready, let source = context.engine.siteControlTarget?.tabID else {
      return ["name": name, "passed": false, "detail": "Source page did not load"]
    }
    let prior = Set(tabs(in: host).map(\.id))
    let clicked: Bool = await withCheckedContinuation { continuation in
      runtime.submitTrustedProbeClick(inTabID: source.uuidString, elementID: elementID) {
        continuation.resume(returning: $0)
      }
    }
    let adopted = await wait {
      tabs(in: host).contains { !prior.contains($0.id) && $0.url.path == "/cross-site-b" }
    }
    let destination = tabs(in: host)
      .first { !prior.contains($0.id) && $0.url.path == "/cross-site-b" }
    let sourceState = await document(runtime, tab: source)
    let destinationState: [String: Any]?
    if let destination {
      destinationState = await document(runtime, tab: destination.id)
    } else {
      destinationState = nil
    }
    let passed = ShaarTabAdoptionEvidence(
      clicked: clicked, adopted: adopted, expectedElementID: elementID,
      clickedElementID: sourceState?["clicked"] as? String,
      trustedGesture: sourceState?["trusted"] as? String,
      destinationMarker: destinationState?["marker"] as? String,
      destinationHost: destination?.url.host,
      destinationBelongsToWindow: destination.map {
        runtime.windowID(forTabID: $0.id.uuidString) == context.nativeID
      } == true,
      rendererFailuresAreEmpty: host.contexts.values.allSatisfy {
        $0.store.rendererFailures.isEmpty
      },
      allWindowsHidden: NSApp.windows.allSatisfy { !$0.isVisible }).passed
    return [
      "name": name, "passed": passed, "clicked": clicked, "adopted": adopted,
      "trusted": sourceState?["trusted"] ?? "",
      "destination": destination?.url.absoluteString ?? "",
      "marker": destinationState?["marker"] ?? "",
    ]
  }

  private static func tabs(in host: NativeBrowserHost) -> [BrowserTab] {
    host.contexts.values.flatMap { $0.store.session.spaces.flatMap(\.tabs) }
  }

  private static func document(_ runtime: ARCChromiumRuntime, tab: UUID) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tab.uuidString,
        script:
          "({clicked:document.documentElement.dataset.clicked||'',trusted:document.documentElement.dataset.trusted||'',marker:document.getElementById('destination')?.innerText||''})"
      ) {
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
