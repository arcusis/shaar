// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct WorkspaceProbeEvidenceTests {
  @Test func documentRequiresFixtureInstanceAndExpectedAddress() throws {
    let json = "{\"fixture\":\"v1\",\"instance\":\"document-1\",\"url\":\"https://fixture.test/\"}"
    #expect(WorkspaceProbeEvidence.fixtureDocument(json) != nil)
    #expect(WorkspaceProbeEvidence.fixtureDocument(json, address: "https://fixture.test/") != nil)
    #expect(WorkspaceProbeEvidence.fixtureDocument(json, address: "https://other.test/") == nil)

    for invalid in [
      nil,
      "{",
      "[]",
      "{\"fixture\":\"v2\",\"instance\":\"document-1\"}",
      "{\"fixture\":\"v1\"}",
      "{\"fixture\":\"v1\",\"instance\":\"\"}",
      "{\"fixture\":\"v1\",\"instance\":9}",
    ] {
      #expect(WorkspaceProbeEvidence.fixtureDocument(invalid) == nil)
    }
  }
}
