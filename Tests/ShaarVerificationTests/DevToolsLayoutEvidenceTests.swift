// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite @MainActor struct DevToolsLayoutEvidenceTests {
  @Test func rememberedDockAcceptsOnePointRoundingButRejectsGeometryChanges() {
    let initial = NSRect(x: 0, y: 0, width: 428, height: 660)
    #expect(
      DevToolsProbe.rememberedDockFrameMatches(
        initial, NSRect(x: 0, y: 0, width: 429, height: 660)))
    #expect(
      !DevToolsProbe.rememberedDockFrameMatches(
        initial, NSRect(x: 0, y: 0, width: 431, height: 660)))
    #expect(!DevToolsProbe.rememberedDockFrameMatches(initial, nil))
  }

  @Test func dockAuditRequiresOpenGeometryAndARealResize() {
    let state: [AnyHashable: Any] = [
      "open": true, "pageWidth": 700.0, "containerWidth": 1000.0, "pageHeight": 600.0,
      "sameWindow": true, "sameContainer": true, "frontendHitNearTabStrip": true,
      "pageAboveFrontend": true, "frontendCoversContainer": true, "geometryReady": true,
      "gap": 0.0, "frontendWidth": 1000.0, "frontendHeight": 600.0,
    ]
    #expect(DevToolsDockEvidence.matches(state, open: true))
    #expect(!DevToolsDockEvidence.matches(state, open: false))
    #expect(!DevToolsDockEvidence.matches(state, open: true, previousWidth: 995))
    #expect(DevToolsDockEvidence.matches(state, open: true, previousWidth: 980))
    var broken = state
    broken["sameWindow"] = false
    #expect(!DevToolsDockEvidence.matches(broken, open: true))
  }

  @Test func closedDockRequiresThePageToFillItsContainer() {
    let state: [AnyHashable: Any] = [
      "open": false, "pageWidth": 1000.5, "containerWidth": 1000.0, "pageHeight": 600.0,
    ]
    #expect(DevToolsDockEvidence.matches(state, open: false))
    var undersized = state
    undersized["pageWidth"] = 998.9
    #expect(!DevToolsDockEvidence.matches(undersized, open: false))
  }
}
