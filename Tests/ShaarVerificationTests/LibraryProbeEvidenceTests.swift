// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct LibraryProbeEvidenceTests {
  @Test func acceptsOnlyAuthoredFixtureObjects() throws {
    let document = try #require(
      LibraryProbeEvidence.fixtureDocument("{\"fixture\":\"v1\",\"cookie\":\"account=alpha\"}"))
    #expect(document["cookie"] as? String == "account=alpha")
  }

  @Test func rejectsMissingMalformedAndNonFixturePayloads() {
    for json in [nil, "{", "[]", "{}", "{\"fixture\":\"v2\"}", "{\"fixture\":1}"] {
      #expect(LibraryProbeEvidence.fixtureDocument(json) == nil)
    }
  }

  @Test func identityCheckpointRequiresDistinctSpaceFolderAndBookmarkIDs() {
    let ids = (0..<6).map { _ in UUID() }
    #expect(LibraryProbeEvidence.hasDistinctIdentityIDs(ids))
    #expect(!LibraryProbeEvidence.hasDistinctIdentityIDs([ids[0], ids[0], ids[2]]))
    #expect(LibraryProbeEvidence.hasDistinctIdentityIDs([]))
  }
}
