// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

@MainActor
struct DevToolsDockProbe {
  let runtime: ARCShaarRuntime
  let model: InspectorModel
  let windowID: String
  var contextID: String?
  let fixture: URL

  func run(record: (String) -> Void) async throws {
    let window: NSWindow?
    if let contextID {
      window = runtime.window(forPrivateWindowID: windowID, contextID: contextID)
    } else {
      window = runtime.window(forID: windowID)
    }
    guard let window, !window.isVisible else { throw InspectorFailure("Dock window unavailable.") }
    let original = window.frame
    defer { window.setFrame(original, display: false) }
    try await toggle()
    try await wait("native dock opens") { try audit(open: true) }
    record("nativeFrontendAttached")
    guard
      let initial = ARCProbeDevToolsDockAudit(
        runtime, model.target.tabID.uuidString, windowID, contextID),
      let initialWidth = initial["containerWidth"] as? Double
    else { throw InspectorFailure("Initial page container width unavailable.") }
    window.setContentSize(NSSize(width: 1000, height: 700))
    window.contentView?.layoutSubtreeIfNeeded()
    try await wait("native dock resizes") { try audit(open: true, previousWidth: initialWidth) }
    record("nativeDockResizes")
    try await toggle()
    try await wait("native dock closes and page restores") { try audit(open: false) }
    record("closeRestoresFullPage")
    let destination = fixture.appending(queryItems: [
      URLQueryItem(name: "after-dock", value: UUID().uuidString)
    ])
    let accepted: Bool
    if let contextID {
      accepted = runtime.navigatePrivateTabID(
        model.target.tabID.uuidString, windowID: windowID, contextID: contextID,
        url: destination.absoluteString)
    } else {
      accepted = runtime.navigateTabID(
        model.target.tabID.uuidString, profileID: model.target.profileID.uuidString,
        windowID: windowID, url: destination.absoluteString)
    }
    guard accepted else { throw InspectorFailure("Navigation after DevTools close rejected.") }
    try await wait("navigation after DevTools close") {
      guard
        let state = try? await model.evaluate(
          "({url:location.href,ready:document.readyState,body:!!document.body})") as? [String: Any]
      else { return false }
      return state["url"] as? String == destination.absoluteString
        && state["ready"] as? String == "complete" && state["body"] as? Bool == true
    }
    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
      throw InspectorFailure("Dock probe exposed a window.")
    }
    record("engineNavigatesAfterClose")
  }

  private func toggle() async throws {
    if let contextID {
      try await runtime.toggleDevTools(
        forPrivateTabID: model.target.tabID.uuidString, windowID: windowID, contextID: contextID)
    } else {
      try await runtime.toggleDevTools(forTabID: model.target.tabID.uuidString)
    }
  }

  private func audit(open: Bool, previousWidth: Double? = nil) throws -> Bool {
    guard
      let state = ARCProbeDevToolsDockAudit(
        runtime, model.target.tabID.uuidString, windowID, contextID)
    else { throw InspectorFailure("Native frontend audit unavailable.") }
    let bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    FileHandle.standardError.write(Data("DevTools dock audit: ".utf8) + bytes + Data("\n".utf8))
    guard state["allWindowsHidden"] as? Bool == true else {
      throw InspectorFailure("DevTools exposed a native window.")
    }
    guard state["open"] as? Bool == open,
      let page = state["pageWidth"] as? Double, let host = state["containerWidth"] as? Double,
      let height = state["pageHeight"] as? Double, host > 0, height > 0
    else { return false }
    if let previousWidth, abs(host - previousWidth) <= 10 { return false }
    if !open { return abs(page - host) <= 1 }
    guard state["sameWindow"] as? Bool == true,
      state["sameContainer"] as? Bool == true, state["nonOverlapping"] as? Bool == true,
      let frontend = state["frontendWidth"] as? Double,
      let frontendHeight = state["frontendHeight"] as? Double
    else { return false }
    return abs(page - host * 0.6) <= 2 && abs(frontend - host * 0.4) <= 2 && frontendHeight > 0
  }

  private func wait(_ name: String, until ready: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while try await !ready() {
      guard Date() < deadline else { throw InspectorFailure("Timed out waiting for \(name).") }
      try await Task.sleep(for: .milliseconds(100))
    }
  }
}
