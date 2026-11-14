// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct HttpsOnlyPageEvidenceTests {
  private let fixtureMarker = "plain-http-loaded"

  @Test func upgradeRequiresHiddenWarningAndRejectsUnupgradedFixture() {
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "https://example.test/", text: "Your connection is not secure",
      expectsUpgrade: true, windowsHidden: true, fixtureMarker: fixtureMarker) == .passed)
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "http://example.test/", text: fixtureMarker,
      expectsUpgrade: true, windowsHidden: true, fixtureMarker: fixtureMarker)
      == .failed("Public HTTP page loaded without an HTTPS-only warning."))
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "https://example.test/", text: "HTTPS warning",
      expectsUpgrade: true, windowsHidden: false, fixtureMarker: fixtureMarker)
      == .failed("The HTTPS-only warning was visible on screen."))
  }

  @Test func plainFixturePassesOnlyOverHTTPWhileWindowsStayHidden() {
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "http://127.0.0.1:43123/account", text: fixtureMarker,
      expectsUpgrade: false, windowsHidden: true, fixtureMarker: fixtureMarker) == .passed)
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "https://127.0.0.1:43123/account", text: fixtureMarker,
      expectsUpgrade: false, windowsHidden: true, fixtureMarker: fixtureMarker) == .retry)
    #expect(HttpsOnlyPageEvidence.evaluate(
      href: "http://127.0.0.1:43123/account", text: fixtureMarker,
      expectsUpgrade: false, windowsHidden: false, fixtureMarker: fixtureMarker)
      == .failed("The HTTP fixture was visible on screen."))
  }
}
