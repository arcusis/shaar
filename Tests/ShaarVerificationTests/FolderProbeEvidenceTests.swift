// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct FolderProbeEvidenceTests {
  @Test func fixtureDocumentRequiresANonemptyInstance() throws {
    let document = try #require(
      FolderProbeEvidence.fixtureDocument("{\"fixture\":\"v1\",\"instance\":\"page-1\"}"))
    #expect(document["instance"] as? String == "page-1")

    for json in [
      nil,
      "{",
      "[]",
      "{}",
      "{\"fixture\":\"v2\",\"instance\":\"page-1\"}",
      "{\"fixture\":\"v1\"}",
      "{\"fixture\":\"v1\",\"instance\":\"\"}",
      "{\"fixture\":\"v1\",\"instance\":7}",
    ] {
      #expect(FolderProbeEvidence.fixtureDocument(json) == nil)
    }
  }
}
