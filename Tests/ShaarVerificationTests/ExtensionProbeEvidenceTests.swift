// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ExtensionProbeEvidenceTests {
  @Test func readinessRequiresAuthoredFixtureAndNonemptyStorageState() {
    #expect(
      ExtensionProbeEvidence.contentScriptReady([
        "fixture": "v1", "extensionAccount": "none",
      ]))
    for page: [String: Any]? in [
      nil,
      [:],
      ["fixture": "v2", "extensionAccount": "alpha"],
      ["fixture": "v1"],
      ["fixture": "v1", "extensionAccount": ""],
      ["fixture": "v1", "extensionAccount": true],
    ] {
      #expect(!ExtensionProbeEvidence.contentScriptReady(page))
    }
  }
}
