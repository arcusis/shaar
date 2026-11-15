// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite("Private product canceled close")
struct PrivateProductCancelledCloseTests {
  @Test func closeRetainsTheActualTabCountAfterEarlierTabRemoval() {
    #expect(
      PrivateProductHostProbe.cancelledCloseRetainsOwner(
        cancelled: true, ownerStillOwned: true, tabCountBefore: 2, tabCountAfter: 2,
        storeRetained: true, hostingRetained: true))
  }

  @Test func closeFailsWhenItDropsAOwnedTab() {
    #expect(
      !PrivateProductHostProbe.cancelledCloseRetainsOwner(
        cancelled: true, ownerStillOwned: true, tabCountBefore: 2, tabCountAfter: 1,
        storeRetained: true, hostingRetained: true))
  }
}
