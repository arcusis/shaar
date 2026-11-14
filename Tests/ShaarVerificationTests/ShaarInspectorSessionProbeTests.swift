// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarInspectorSessionProbeTests {
  @Test func privatePresentationRequiresTheSelectedNativeViewInTheHiddenWindow() {
    let tabID = UUID().uuidString
    let view: [String: Any] = [
      "hasWindow": true,
      "inExpectedWindow": true,
      "hidden": false,
      "hiddenOrHasHiddenAncestor": false,
      "windowVisible": false,
    ]
    let state: [String: Any] = [
      "tabID": tabID,
      "nativeStateSupported": true,
      "selectedNativeTab": true,
      "displayedNativeWebContents": true,
      "nativeViewHierarchy": view,
    ]
    let audit: [AnyHashable: Any] = ["allWindowsHidden": true, "documentStates": [state]]

    let complete = ShaarInspectorSessionProbe.privatePresentationReady(audit, tabID: tabID)
    let visibleWindowsAccepted = ShaarInspectorSessionProbe.privatePresentationReady(
      ["allWindowsHidden": false, "documentStates": [state]], tabID: tabID)
    let missingStatesAccepted = ShaarInspectorSessionProbe.privatePresentationReady(
      ["allWindowsHidden": true], tabID: tabID)
    let missingSelectedTabAccepted = ShaarInspectorSessionProbe.privatePresentationReady(
      ["allWindowsHidden": true, "documentStates": [[String: Any]]()], tabID: tabID)
    #expect(complete)
    #expect(!visibleWindowsAccepted)
    #expect(!missingStatesAccepted)
    #expect(!missingSelectedTabAccepted)

    for key in ["nativeStateSupported", "selectedNativeTab", "displayedNativeWebContents"] {
      var invalidState = state
      invalidState[key] = false
      let accepted = ShaarInspectorSessionProbe.privatePresentationReady(
        ["allWindowsHidden": true, "documentStates": [invalidState]], tabID: tabID)
      #expect(!accepted)
    }

    for key in ["hasWindow", "inExpectedWindow"] {
      var invalidView = view
      invalidView[key] = false
      var invalidState = state
      invalidState["nativeViewHierarchy"] = invalidView
      let accepted = ShaarInspectorSessionProbe.privatePresentationReady(
        ["allWindowsHidden": true, "documentStates": [invalidState]], tabID: tabID)
      #expect(!accepted)
    }
    var visibleWindow = view
    visibleWindow["windowVisible"] = true
    var stateWithVisibleWindow = state
    stateWithVisibleWindow["nativeViewHierarchy"] = visibleWindow
    let visibleWindowAccepted = ShaarInspectorSessionProbe.privatePresentationReady(
      ["allWindowsHidden": true, "documentStates": [stateWithVisibleWindow]], tabID: tabID)
    #expect(!visibleWindowAccepted)
    for key in ["hidden", "hiddenOrHasHiddenAncestor"] {
      var invalidView = view
      invalidView[key] = true
      var invalidState = state
      invalidState["nativeViewHierarchy"] = invalidView
      let accepted = ShaarInspectorSessionProbe.privatePresentationReady(
        ["allWindowsHidden": true, "documentStates": [invalidState]], tabID: tabID)
      #expect(!accepted)
    }
  }
}
