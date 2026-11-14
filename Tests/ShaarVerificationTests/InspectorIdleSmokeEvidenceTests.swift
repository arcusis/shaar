// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct InspectorIdleSmokeEvidenceTests {
  @Test func probeAcceptsOnlyHTTPOnTheLiteralLoopbackAddress() {
    #expect(
      InspectorIdleSmokeEvidence.acceptsPageURL(URL(string: "http://127.0.0.1:8080/inspect")))
    #expect(!InspectorIdleSmokeEvidence.acceptsPageURL(nil))
    #expect(
      !InspectorIdleSmokeEvidence.acceptsPageURL(URL(string: "https://127.0.0.1:8443/inspect")))
    #expect(
      !InspectorIdleSmokeEvidence.acceptsPageURL(URL(string: "http://localhost:8080/inspect")))
    #expect(
      !InspectorIdleSmokeEvidence.acceptsPageURL(
        URL(string: "http://127.0.0.1.example.invalid:8080/inspect")))
  }
}
