// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
import Foundation

@testable import ArcusisBrowser

enum DevToolsDockEvidence {
  static func allWindowsAreHidden(_ state: [AnyHashable: Any]) -> Bool {
    boolean(state["allWindowsHidden"]) == true
  }

  static func matches(_ state: [AnyHashable: Any], open: Bool, previousWidth: Double? = nil) -> Bool {
    guard boolean(state["open"]) == open,
      let page = number(state["pageWidth"]),
      let host = number(state["containerWidth"]),
      let height = number(state["pageHeight"]),
      host > 0, height > 0
    else { return false }
    if let previousWidth, abs(host - previousWidth) <= 10 { return false }
    if !open { return abs(page - host) <= 1 }
    guard boolean(state["sameWindow"]) == true,
      boolean(state["sameContainer"]) == true,
      boolean(state["frontendHitNearTabStrip"]) == true,
      boolean(state["pageAboveFrontend"]) == true,
      boolean(state["frontendCoversContainer"]) == true,
      boolean(state["geometryReady"]) == true,
      let gap = number(state["gap"]),
      let frontend = number(state["frontendWidth"]),
      let frontendHeight = number(state["frontendHeight"])
    else { return false }
    return gap <= 1 && page > 0 && page < host && abs(frontend - host) <= 1
      && frontendHeight > 0
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.doubleValue
  }
}

enum DevToolsDockProbeEvidence {
  static func geometryMatches(
    _ state: [AnyHashable: Any], open: Bool, previousWidth: Double? = nil
  ) -> Bool {
    DevToolsDockEvidence.matches(state, open: open, previousWidth: previousWidth)
  }
}

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
    guard DevToolsDockEvidence.allWindowsAreHidden(state) else {
      throw InspectorFailure("DevTools exposed a native window.")
    }
    return DevToolsDockEvidence.matches(state, open: open, previousWidth: previousWidth)
  }

  private func wait(_ name: String, until ready: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while try await !ready() {
      guard Date() < deadline else { throw InspectorFailure("Timed out waiting for \(name).") }
      try await Task.sleep(for: .milliseconds(100))
    }
  }
}
