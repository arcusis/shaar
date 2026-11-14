// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct NativeHostIdentityCheckpointEvidenceTests {
  @Test func retainedAndClosedWindowIDsMustBeUniqueAndDisjoint() {
    let first = UUID()
    let second = UUID()
    let closed = UUID()
    #expect(
      NativeHostIdentityCheckpointEvidence.hasDistinctWindowIDs(
        retained: [first, second], closed: [closed]))
    #expect(
      !NativeHostIdentityCheckpointEvidence.hasDistinctWindowIDs(
        retained: [first, first], closed: [closed]))
    #expect(
      !NativeHostIdentityCheckpointEvidence.hasDistinctWindowIDs(
        retained: [first, second], closed: [first]))
    #expect(
      !NativeHostIdentityCheckpointEvidence.hasDistinctWindowIDs(
        retained: [first, second], closed: [closed, closed]))
  }

  @Test func nativeTabCheckpointIDsMustBeDistinct() {
    let first = UUID()
    let second = UUID()
    let stale = UUID()
    #expect(NativeHostIdentityCheckpointEvidence.hasDistinctTabIDs([first, second, stale]))
    #expect(!NativeHostIdentityCheckpointEvidence.hasDistinctTabIDs([first, second, first]))
  }
}
