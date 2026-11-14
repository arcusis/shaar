// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
import Foundation

@testable import ShaarVerification

@Suite struct WorkspaceProbeIdentityTests {
  @Test func persistedIdentityRestoresWindowAndTabIDsWithOptionalDocuments() throws {
    let identity = WorkspaceProbeIdentity(
      first: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      second: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      alpha: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      beta: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      firstPin: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      secondPin: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
      firstOrdinary: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
      betaTab: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
      closed: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
      firstDocument: "first-instance", secondDocument: "second-instance")
    let restored = try JSONDecoder().decode(
      WorkspaceProbeIdentity.self, from: JSONEncoder().encode(identity))
    #expect(restored == identity)
  }

  @Test func persistedIdentityRejectsMissingOrMalformedRequiredIDs() throws {
    let missing = Data(#"{"first":"00000000-0000-0000-0000-000000000001"}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(WorkspaceProbeIdentity.self, from: missing)
    }
    let malformed = Data(#"{"first":"not-a-uuid"}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(WorkspaceProbeIdentity.self, from: malformed)
    }
  }
}
