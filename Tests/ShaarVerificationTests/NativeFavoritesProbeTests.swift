// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Native Favorite checkpoint validation")
struct NativeFavoritesProbeTests {
  @Test func restartCheckpointRequiresExactlyTwoDistinctWindowIDs() {
    let first = UUID()
    let second = UUID()
    #expect(NativeFavoritesCheckpoint.hasValidWindowIDs([first, second]))
    #expect(!NativeFavoritesCheckpoint.hasValidWindowIDs([]))
    #expect(!NativeFavoritesCheckpoint.hasValidWindowIDs([first]))
    #expect(!NativeFavoritesCheckpoint.hasValidWindowIDs([first, second, UUID()]))
    #expect(!NativeFavoritesCheckpoint.hasValidWindowIDs([first, first]))
  }
}
