// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite struct ShaarFirstTabProbeTests {
  @Test func privatePresentationRequiresTheExactSelectedVisibleViewInAHiddenWindow() {
    let state: [String: Any] = [
      "tabID": "fixture", "nativeStateSupported": true, "selectedNativeTab": true,
      "displayedNativeWebContents": true,
      "nativeViewHierarchy": [
        "inExpectedWindow": true, "hasWindow": true, "hidden": false,
        "hiddenOrHasHiddenAncestor": false, "windowVisible": false,
      ],
    ]
    let audit: [AnyHashable: Any] = ["allWindowsHidden": true, "documentStates": [state]]
    #expect(ShaarInspectorSessionProbe.privatePresentationReady(audit, tabID: "fixture"))
    #expect(!ShaarInspectorSessionProbe.privatePresentationReady(audit, tabID: "other"))
    #expect(!ShaarInspectorSessionProbe.privatePresentationReady([:], tabID: "fixture"))
    for field in ["nativeStateSupported", "selectedNativeTab", "displayedNativeWebContents"] {
      var changed = state
      changed[field] = false
      let ready = ShaarInspectorSessionProbe.privatePresentationReady(
        ["allWindowsHidden": true, "documentStates": [changed]], tabID: "fixture")
      #expect(!ready)
    }
    for field in ["hidden", "hiddenOrHasHiddenAncestor", "windowVisible"] {
      var changed = state
      var hierarchy = state["nativeViewHierarchy"] as! [String: Bool]
      hierarchy[field] = true
      changed["nativeViewHierarchy"] = hierarchy
      let ready = ShaarInspectorSessionProbe.privatePresentationReady(
        ["allWindowsHidden": true, "documentStates": [changed]], tabID: "fixture")
      #expect(!ready)
    }
  }

  @Test func missingArgumentsFailBeforeStartingTheEngine() {
    #expect(ShaarFirstTabProbe.run(arguments: []) == 1)
    #expect(
      ShaarFirstTabProbe.run(arguments: [
        "--probe-framework", "/nonexistent/framework",
      ]) == 1)
  }

  @Test func requestedURLAcceptsNormalizedRootAndRejectsOtherNavigation() {
    let requested = URL(string: "https://example.com")!
    #expect(
      ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://example.com/")!, requested: requested))
    #expect(
      !ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://other.example.com/")!, requested: requested))
    #expect(
      !ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://example.com/other")!, requested: requested))
    #expect(!ShaarFirstTabProbe.matchesRequestedURL(nil, requested: requested))
  }
}
