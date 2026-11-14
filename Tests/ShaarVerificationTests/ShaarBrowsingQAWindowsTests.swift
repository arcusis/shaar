// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAWindowsTests {
  @Test func dragVerdictRequiresBothModelMembershipsAndEngineOwnership() {
    #expect(
      ShaarBrowsingQA.windowsDragPassed(
        accepted: true, sourceStillHasTab: false, destinationHasTab: true, engineMoved: true))
    #expect(
      !ShaarBrowsingQA.windowsDragPassed(
        accepted: true, sourceStillHasTab: false, destinationHasTab: false, engineMoved: true))
    #expect(
      !ShaarBrowsingQA.windowsDragPassed(
        accepted: true, sourceStillHasTab: true, destinationHasTab: true, engineMoved: true))
  }
}
