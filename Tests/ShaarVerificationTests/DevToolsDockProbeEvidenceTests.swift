// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct DevToolsDockProbeEvidenceTests {
  @Test func openDockRequiresAttachedFrontendAndContainedPageGeometry() {
    let open: [AnyHashable: Any] = [
      "open": true,
      "pageWidth": 600.0,
      "containerWidth": 1000.0,
      "pageHeight": 600.0,
      "sameWindow": true,
      "sameContainer": true,
      "frontendHitNearTabStrip": true,
      "pageAboveFrontend": true,
      "frontendCoversContainer": true,
      "geometryReady": true,
      "gap": 0.5,
      "frontendWidth": 1000.0,
      "frontendHeight": 300.0,
    ]
    #expect(DevToolsDockProbeEvidence.geometryMatches(open, open: true))
    #expect(!DevToolsDockProbeEvidence.geometryMatches(open, open: false))
    #expect(
      !DevToolsDockProbeEvidence.geometryMatches(open, open: true, previousWidth: 995.0))

    var detached = open
    detached["sameWindow"] = false
    #expect(!DevToolsDockProbeEvidence.geometryMatches(detached, open: true))
    var gap = open
    gap["gap"] = 1.1
    #expect(!DevToolsDockProbeEvidence.geometryMatches(gap, open: true))
    var pageOverflows = open
    pageOverflows["pageWidth"] = 1000.1
    #expect(!DevToolsDockProbeEvidence.geometryMatches(pageOverflows, open: true))
  }

  @Test func closedDockRequiresPageToFillItsContainerWithinOnePoint() {
    let closed: [AnyHashable: Any] = [
      "open": false,
      "pageWidth": 999.0,
      "containerWidth": 1000.0,
      "pageHeight": 600.0,
    ]
    #expect(DevToolsDockProbeEvidence.geometryMatches(closed, open: false))
    var wrongWidth = closed
    wrongWidth["pageWidth"] = 998.9
    #expect(!DevToolsDockProbeEvidence.geometryMatches(wrongWidth, open: false))
    var missingHeight = closed
    missingHeight.removeValue(forKey: "pageHeight")
    #expect(!DevToolsDockProbeEvidence.geometryMatches(missingHeight, open: false))
  }
}
