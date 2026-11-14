// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct FolderProbeIdentityTests {
  @Test func identitiesRoundTripEveryRequiredUUID() throws {
    let expected = FolderIdentities(
      source: UUID(), destination: UUID(), root: UUID(), child: UUID(), parent: UUID(),
      tabs: [UUID(), UUID()])
    let data = try JSONEncoder().encode(expected)
    #expect(try JSONDecoder().decode(FolderIdentities.self, from: data) == expected)
  }

  @Test func identitiesRejectMalformedAndMissingRequiredValues() throws {
    let malformed = Data(
      #"{"source":"not-a-uuid","destination":"00000000-0000-0000-0000-000000000001","root":"00000000-0000-0000-0000-000000000002","child":"00000000-0000-0000-0000-000000000003","parent":"00000000-0000-0000-0000-000000000004","tabs":[]}"#.utf8)
    let missing = Data(#"{"source":"00000000-0000-0000-0000-000000000001"}"#.utf8)

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(FolderIdentities.self, from: malformed)
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(FolderIdentities.self, from: missing)
    }
  }
}
