// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ExtensionProbeParsingTests {
  @Test func popupEvidenceParsesObjectsAndJSONFragments() {
    #expect(
      ExtensionProbe.popupEvidence("{\"account\":\"alpha\"}") as? [String: String]
        == ["account": "alpha"])
    #expect(ExtensionProbe.popupEvidence("true") as? Bool == true)
    #expect(ExtensionProbe.popupEvidence("7") as? Int == 7)
    #expect(ExtensionProbe.popupEvidence("null") is NSNull)
  }

  @Test func popupEvidenceRejectsMissingAndMalformedJSON() {
    #expect(ExtensionProbe.popupEvidence(nil) == nil)
    #expect(ExtensionProbe.popupEvidence("not JSON") == nil)
  }
}
