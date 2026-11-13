// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite("Closed-tab recovery checkpoint")
struct ReopenProbeTests {
  @Test func checkpointRequiresDistinctSpaceFolderAndTabIDs() {
    let values = (0..<5).map { _ in UUID() }
    let valid = RecoveryIdentities(
      alpha: values[0], beta: values[1], folder: values[2],
      alphaClosed: values[3], betaClosed: values[4])
    #expect(valid.hasDistinctIDs)

    let duplicate = RecoveryIdentities(
      alpha: values[0], beta: values[1], folder: values[2],
      alphaClosed: values[3], betaClosed: values[3])
    #expect(!duplicate.hasDistinctIDs)
  }
}
