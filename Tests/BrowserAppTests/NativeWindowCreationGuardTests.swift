// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test @MainActor func failedWindowInitializationClosesItsUnownedNativeID() {
  var closes = 0
  let guardToken = NativeWindowCreationGuard { closes += 1 }

  guardToken.closeIfUnowned()
  guardToken.closeIfUnowned()

  #expect(closes == 1)
}

@Test @MainActor func successfullyAttachedWindowTransfersNativeIDOwnership() {
  var closes = 0
  let guardToken = NativeWindowCreationGuard { closes += 1 }

  guardToken.transferToOwner()
  guardToken.closeIfUnowned()

  #expect(closes == 0)
}
