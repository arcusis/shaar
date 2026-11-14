// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct WindowClientProbeEvidenceTests {
  @Test func clientDocumentRequiresAuthoredFixtureAndInstance() {
    #expect(WindowClientProbeEvidence.hasAuthoredDocument(["fixture": "v1", "instance": "tab-1"]))
    for invalid in [
      [:],
      ["fixture": "v2", "instance": "tab-1"],
      ["fixture": "v1"],
      ["fixture": "v1", "instance": ""],
      ["fixture": "v1", "instance": false],
    ] as [[String: Any]] {
      #expect(!WindowClientProbeEvidence.hasAuthoredDocument(invalid))
    }
  }
}
