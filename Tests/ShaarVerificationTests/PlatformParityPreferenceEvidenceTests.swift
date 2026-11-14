// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PlatformParityPreferenceEvidenceTests {
  @Test func booleanCookieControlModeIsNotReportedAsANumericPreference() {
    let values = PlatformParityPreferenceEvidence.excerpt([
      "profile": ["cookie_controls_mode": true],
    ])
    #expect(values["profile.cookie_controls_mode"] == nil)
  }

  @Test func extractsJSONBooleansWithoutTreatingNumbersAsFlags() {
    let values = PlatformParityPreferenceEvidence.excerpt([
      "safebrowsing": ["enabled": true, "enhanced": false],
      "https_only_mode_enabled": 1,
      "autofill": ["profile_enabled": true, "credit_card_enabled": "false"],
      "credentials_enable_service": false,
      "profile": ["cookie_controls_mode": 2],
    ])
    #expect(values["safebrowsing.enabled"] == "true")
    #expect(values["safebrowsing.enhanced"] == "false")
    #expect(values["https_only_mode_enabled"] == nil)
    #expect(values["autofill.profile_enabled"] == "true")
    #expect(values["autofill.credit_card_enabled"] == nil)
    #expect(values["credentials_enable_service"] == "false")
    #expect(values["profile.cookie_controls_mode"] == "2")
  }
}
