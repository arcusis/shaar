// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct HttpsOnlyProbeEvidenceTests {
  @Test func expectedUpgradeRequiresWarningInsteadOfThePlainHttpFixture() {
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "chrome-error://chromewebdata/", text: "This connection is not secure", expectsUpgrade: true)
        == .upgradeWarning)
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "http://trackertest.org:49195/plain",
        text: HttpsOnlyProbeEvidence.fixtureMarker, expectsUpgrade: true)
        == .unexpectedHttpPage)
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "http://trackertest.org:49195/plain", text: "Loading", expectsUpgrade: true)
        == .waiting)
  }

  @Test func disabledUpgradeRequiresTheHttpFixtureAndIgnoresSecureOrUnrelatedPages() {
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "http://trackertest.org:49195/plain",
        text: HttpsOnlyProbeEvidence.fixtureMarker, expectsUpgrade: false)
        == .loadedHttpFixture)
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "https://trackertest.org/plain",
        text: HttpsOnlyProbeEvidence.fixtureMarker, expectsUpgrade: false)
        == .waiting)
    #expect(
      HttpsOnlyProbeEvidence.verdict(
        href: "http://trackertest.org:49195/plain", text: "Unrelated HTTPS page", expectsUpgrade: false)
        == .waiting)
  }
}
