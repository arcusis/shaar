// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct DevToolsDockEvidenceTests {
  private var openState: [AnyHashable: Any] {
    [
      "open": true, "pageWidth": 700.0, "containerWidth": 1000.0, "pageHeight": 600.0,
      "sameWindow": true, "sameContainer": true, "frontendHitNearTabStrip": true,
      "pageAboveFrontend": true, "frontendCoversContainer": true, "geometryReady": true,
      "gap": 0.0, "frontendWidth": 1000.0, "frontendHeight": 400.0,
    ]
  }

  @Test func openDockRequiresAllStrictFlagsAndGeometry() {
    #expect(DevToolsDockEvidence.matches(openState, open: true))
    #expect(DevToolsDockEvidence.matches(openState, open: true, previousWidth: 800))
    #expect(!DevToolsDockEvidence.matches(openState, open: true, previousWidth: 995))

    for key in [
      "sameWindow", "sameContainer", "frontendHitNearTabStrip", "pageAboveFrontend",
      "frontendCoversContainer", "geometryReady",
    ] {
      var invalid = openState
      invalid[key] = false
      #expect(!DevToolsDockEvidence.matches(invalid, open: true))
      invalid[key] = 1
      #expect(!DevToolsDockEvidence.matches(invalid, open: true))
    }
    for key in ["pageWidth", "containerWidth", "pageHeight", "gap", "frontendWidth", "frontendHeight"] {
      var invalid = openState
      invalid[key] = true
      #expect(!DevToolsDockEvidence.matches(invalid, open: true))
    }
  }

  @Test func closedDockRequiresThePageToFillItsContainer() {
    let state: [AnyHashable: Any] = [
      "open": false, "pageWidth": 999.5, "containerWidth": 1000.0, "pageHeight": 600.0,
    ]
    #expect(DevToolsDockEvidence.matches(state, open: false))
    var invalid = state
    invalid["pageWidth"] = 990.0
    #expect(!DevToolsDockEvidence.matches(invalid, open: false))
    invalid = state
    invalid["open"] = 0
    #expect(!DevToolsDockEvidence.matches(invalid, open: false))
  }

  @Test func hiddenWindowEvidenceMustBeAJSONBoolean() {
    #expect(DevToolsDockEvidence.allWindowsAreHidden(["allWindowsHidden": true]))
    #expect(!DevToolsDockEvidence.allWindowsAreHidden(["allWindowsHidden": false]))
    #expect(!DevToolsDockEvidence.allWindowsAreHidden(["allWindowsHidden": 1]))
    #expect(!DevToolsDockEvidence.allWindowsAreHidden([:]))
  }
}
