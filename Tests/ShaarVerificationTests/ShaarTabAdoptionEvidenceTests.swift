// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarTabAdoptionEvidenceTests {
  @Test func adoptionRequiresTrustedClickCrossSiteDestinationAndHiddenCleanHost() {
    let evidence = ShaarTabAdoptionEvidence(
      clicked: true, adopted: true, expectedElementID: "blank", clickedElementID: "blank",
      trustedGesture: "true", destinationMarker: "Cross-site destination loaded",
      destinationHost: "localhost", destinationBelongsToWindow: true,
      rendererFailuresAreEmpty: true, allWindowsHidden: true)
    #expect(evidence.passed)
    #expect(!ShaarTabAdoptionEvidence(
      clicked: true, adopted: true, expectedElementID: "blank", clickedElementID: "popup",
      trustedGesture: "true", destinationMarker: "Cross-site destination loaded",
      destinationHost: "localhost", destinationBelongsToWindow: true,
      rendererFailuresAreEmpty: true, allWindowsHidden: true).passed)
    #expect(!ShaarTabAdoptionEvidence(
      clicked: true, adopted: true, expectedElementID: "blank", clickedElementID: "blank",
      trustedGesture: "false", destinationMarker: "Cross-site destination loaded",
      destinationHost: "localhost", destinationBelongsToWindow: true,
      rendererFailuresAreEmpty: true, allWindowsHidden: true).passed)
    #expect(!ShaarTabAdoptionEvidence(
      clicked: true, adopted: true, expectedElementID: "blank", clickedElementID: "blank",
      trustedGesture: "true", destinationMarker: "Cross-site destination loaded",
      destinationHost: "localhost", destinationBelongsToWindow: false,
      rendererFailuresAreEmpty: true, allWindowsHidden: true).passed)
    #expect(!ShaarTabAdoptionEvidence(
      clicked: true, adopted: true, expectedElementID: "blank", clickedElementID: "blank",
      trustedGesture: "true", destinationMarker: "Cross-site destination loaded",
      destinationHost: "localhost", destinationBelongsToWindow: true,
      rendererFailuresAreEmpty: true, allWindowsHidden: false).passed)
  }
}
