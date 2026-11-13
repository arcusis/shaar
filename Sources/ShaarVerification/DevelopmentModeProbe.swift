// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Proves framework detection through live hidden WebContents on authored loopback pages.
@MainActor
final class DevelopmentModeProbe {
  static let mode = "dev-mode-only"

  private let engine: BrowserEngine
  private let store: BrowserStore
  private let root: URL
  private let fixture: URL
  private let phase: String
  private var checks: [String] = []
  private var detections: [[String: Any]] = []

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  static func fixtureURL(_ account: URL, path: String) -> URL {
    let base = account.deletingLastPathComponent()
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return (components?.url ?? base).appending(path: path)
  }

  func run() async throws -> [String] {
    do {
      try await checkFixture("devmode-next", framework: .nextJS, selector: "#__next")
      try await checkFixture(
        "devmode-vite", framework: .vite, selector: "script[src='/@vite/client']")
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func checkFixture(
    _ path: String, framework: DevelopmentFramework, selector: String
  ) async throws {
    let url = Self.fixtureURL(fixture, path: path)
    store.perform(.open(url))
    guard let tab = store.session.selectedPage?.tab.id else {
      throw Failure("Dev Mode fixture did not create a selected tab")
    }
    let identity = tab.uuidString
    var audit: [AnyHashable: Any] = [:]
    for _ in 0..<150 {
      audit = engine.runtime.normalProbeSelectionAudit(forTabID: identity)
      if engine.liveTabs.contains(tab), engine.pages[tab]?.loading == false,
        engine.siteControlTarget?.url == url,
        engine.detectedFramework == framework,
        engine.selectedDevelopmentPage?.port == url.port,
        audit["selectedNativeTab"] as? Bool == true,
        audit["displayedNativeWebContents"] as? Bool == true
      {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let selected = audit["selectedNativeTab"] as? Bool == true
    let displayed = audit["displayedNativeWebContents"] as? Bool == true
    guard selected, displayed, engine.detectedFramework == framework,
      engine.isDevelopmentPage, engine.siteControlTarget?.url == url,
      engine.selectedDevelopmentPage?.port == url.port
    else {
      throw Failure(
        "Dev Mode \(framework.rawValue) unavailable: selected=\(selected), displayed=\(displayed), detected=\(engine.detectedFramework?.rawValue ?? "none"), target=\(engine.siteControlTarget?.url.path ?? "none")"
      )
    }
    let script =
      "({path:location.pathname,ready:document.readyState,marker:!!document.querySelector(\(String(reflecting: selector)))})"
    let document = try await evaluate(identity, script: script)
    let ready = ["interactive", "complete"].contains(document["ready"] as? String ?? "")
    guard document["path"] as? String == "/\(path)", ready,
      document["marker"] as? Bool == true
    else { throw Failure("Dev Mode \(framework.rawValue) fixture document is missing its marker") }
    let hidden = engine.runtime.window(forID: engine.windowID)?.isVisible == false
    guard hidden else { throw Failure("Dev Mode probe window became visible") }
    detections.append([
      "framework": framework.rawValue, "path": "/\(path)",
      "host": url.host() ?? "", "port": url.port ?? 0,
      "nativeSelected": selected, "nativeDisplayed": displayed,
      "windowHidden": hidden, "documentReady": ready,
    ])
    checks.append("Dev Mode detects \(framework.rawValue)")
  }

  private func evaluate(_ tab: String, script: String) async throws -> [String: Any] {
    let json: String? = await withCheckedContinuation { continuation in
      engine.runtime.evaluate(inTabID: tab, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let json, let data = json.data(using: .utf8),
      let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Failure("Dev Mode fixture JavaScript evaluation failed") }
    return document
  }

  private func report(error: Error?) throws {
    let value: [String: Any] = [
      "phase": phase, "mode": Self.mode, "passed": error == nil,
      "detections": detections,
      "error": error?.localizedDescription as Any? ?? NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-dev-mode.json"), options: .atomic)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
