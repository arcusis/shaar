// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

/// Verifies cross-command CDP state through the app's normal and private Inspector routes.
/// This hidden check does not prove physical pointer input or visible DevTools presentation.
@MainActor
struct ShaarInspectorSessionProbe {
  let runtime: ARCShaarRuntime
  let engine: BrowserEngine
  let profileID: UUID
  let fixture: URL

  static func privatePresentationReady(_ audit: [AnyHashable: Any], tabID: String) -> Bool {
    guard audit["allWindowsHidden"] as? Bool == true,
      let states = audit["documentStates"] as? [[String: Any]],
      let selected = states.first(where: { $0["tabID"] as? String == tabID }),
      selected["nativeStateSupported"] as? Bool == true,
      selected["selectedNativeTab"] as? Bool == true,
      selected["displayedNativeWebContents"] as? Bool == true,
      let view = selected["nativeViewHierarchy"] as? [String: Any]
    else { return false }
    return view["hasWindow"] as? Bool == true
      && view["inExpectedWindow"] as? Bool == true
      && view["hidden"] as? Bool == false
      && view["hiddenOrHasHiddenAncestor"] as? Bool == false
      && view["windowVisible"] as? Bool == false
  }

  func run(record: (String) -> Void) async throws {
    guard let target = engine.siteControlTarget else {
      throw InspectorFailure("Normal Inspector target is missing.")
    }
    let normal = InspectorModel(target: target, engine: engine)
    var failures: [String] = []
    do {
      try await checkSession(normal)
      record("normalSequentialDOMCSS")
    } catch {
      failures.append("normal: \(error)")
    }
    let privateHost = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false, sourceProfileID: { profileID.uuidString })
    privateHost.installCallbacks()
    defer { privateHost.detach() }
    try privateHost.openWindow()
    try await wait("private window") { privateHost.ownedWindows.count == 1 }
    guard let owner = privateHost.ownedWindows.first else {
      throw InspectorFailure("Private Inspector window is missing.")
    }
    guard
      let calls = ARCProbeTracePrivateSelection(
        runtime,
        {
          owner.store.perform(.open(fixture))
          owner.page.confirmHTTP(useHTTPS: false)
        })
    else { throw InspectorFailure("Private selection tracing requires an owned probe root.") }
    let callBytes = try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys])
    FileHandle.standardError.write(
      Data("Product private selection calls: ".utf8) + callBytes + Data("\n".utf8))
    try await wait("private page load") {
      owner.hosting.layoutSubtreeIfNeeded()
      return owner.page.inspectorTarget?.url == fixture
        && owner.page.selectedState?.loading == false
    }
    guard let privateTarget = owner.page.inspectorTarget else {
      throw InspectorFailure("Private Inspector target is missing.")
    }
    guard
      calls.contains(where: {
        $0["tabID"] as? String == privateTarget.tabID.uuidString
          && $0["windowID"] as? String == owner.windowID
          && $0["contextID"] as? String == owner.contextID
          && $0["accepted"] as? Bool == true
      })
    else { throw InspectorFailure("The product did not select the private Inspector fixture.") }
    record("productSelectedPrivateFixture")
    let model = InspectorModel(target: privateTarget, privateSession: owner.page)
    do {
      try await checkSession(model)
      record("privateSequentialDOMCSS")
      guard let audit = runtime.privateProbeAudit(forContextID: owner.contextID),
        Self.privatePresentationReady(audit, tabID: privateTarget.tabID.uuidString)
      else {
        throw InspectorFailure(
          "Selected private Inspector view is not displayed in its hidden window.")
      }
      let bytes = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
      FileHandle.standardError.write(
        Data("Private native success audit: ".utf8) + bytes + Data("\n".utf8))
      record("privateSelectedViewDisplayed")
    } catch {
      if let audit = runtime.privateProbeAudit(forContextID: owner.contextID) {
        let bytes = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
        FileHandle.standardError.write(
          Data("Private native audit: ".utf8) + bytes + Data("\n".utf8))
      }
      if let document = try? await model.call("DOM.getDocument", params: ["depth": 0]) {
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        FileHandle.standardError.write(Data("Private DOM root: ".utf8) + bytes + Data("\n".utf8))
      }
      let other: String? = await withCheckedContinuation { continuation in
        runtime.evaluatePrivateProbeTabID(
          privateTarget.tabID.uuidString,
          script: "({url:location.href,ready:document.readyState,body:!!document.body})"
        ) { continuation.resume(returning: $0) }
      }
      FileHandle.standardError.write(
        Data("Developer capability comparison: \(other ?? "nil")\n".utf8))
      if CommandLine.arguments.contains("--probe-inspector-capture-diagnostic") {
        await captureDiagnostic(owner, model: model, record: record)
      }
      failures.append("private: \(error)")
    }
    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
      throw InspectorFailure("Inspector session probe exposed a window.")
    }
    record("allWindowsHidden")
    guard failures.isEmpty else { throw InspectorFailure(failures.joined(separator: "; ")) }
  }

  private func captureDiagnostic(
    _ owner: PrivateBrowserHost.Owner, model: InspectorModel, record: (String) -> Void
  ) async {
    let capture: (Data?, String?) = await withCheckedContinuation { continuation in
      runtime.capturePrivateProbeTabID(
        model.target.tabID.uuidString, windowID: owner.windowID, contextID: owner.contextID
      ) { continuation.resume(returning: ($0, $1)) }
    }
    let arguments = CommandLine.arguments
    if let png = capture.0, let index = arguments.firstIndex(of: "--probe-output"),
      arguments.indices.contains(index + 1)
    {
      let destination = URL(filePath: arguments[index + 1]).deletingLastPathComponent()
        .appending(path: "private-capture-diagnostic.png")
      do {
        try png.write(to: destination)
        FileHandle.standardError.write(Data("Diagnostic capture: \(destination.path)\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("Diagnostic capture write failed: \(error)\n".utf8))
      }
    } else {
      FileHandle.standardError.write(
        Data("Diagnostic capture failed: \(capture.1 ?? "no PNG")\n".utf8))
    }
    do {
      try await checkSession(model)
      record("diagnosticPrivateSequentialDOMCSSAfterCapture")
    } catch {
      FileHandle.standardError.write(Data("After diagnostic capture: \(error)\n".utf8))
    }
  }

  private func checkSession(_ model: InspectorModel) async throws {
    defer { model.close() }
    do {
      try await wait("Inspector DOM readiness") {
        try await model.evaluate("document.readyState !== 'loading' && !!document.body") as? Bool
          == true
      }
    } catch {
      for awaits in [false, true] {
        let diagnostic = try await model.call(
          "Runtime.evaluate",
          params: [
            "expression":
              "({url:location.href,ready:document.readyState,body:!!document.body,documentElement:!!document.documentElement})",
            "returnByValue": true, "awaitPromise": awaits,
          ])
        let bytes = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        FileHandle.standardError.write(bytes + Data("\n".utf8))
      }
      throw error
    }
    _ = try await model.call("Page.enable")
    _ = try await model.call("DOM.enable")
    _ = try await model.call("DOM.getDocument", params: ["depth": 0])
    _ = try await model.call("CSS.enable")
    let reply = try await model.call(
      "Runtime.evaluate", params: ["expression": "document.body", "objectGroup": "session-probe"])
    guard let objectID = (reply["result"] as? [String: Any])?["objectId"] as? String else {
      throw InspectorFailure("Runtime did not return a DOM object.")
    }
    let node = try await model.call("DOM.requestNode", params: ["objectId": objectID])
    guard let nodeID = node["nodeId"] as? Int, nodeID > 0 else {
      throw InspectorFailure("DOM object did not survive the next Inspector command.")
    }
    let style = try await model.call("CSS.getComputedStyleForNode", params: ["nodeId": nodeID])
    guard let properties = style["computedStyle"] as? [[String: Any]],
      properties.contains(where: { $0["name"] as? String == "display" })
    else {
      throw InspectorFailure("CSS domain or DOM node did not survive the Inspector sequence.")
    }
    _ = try await model.call("Runtime.releaseObjectGroup", params: ["objectGroup": "session-probe"])
  }

  private func wait(_ name: String, until ready: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try await !ready() {
      guard Date() < deadline else { throw InspectorFailure("Timed out waiting for \(name).") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
