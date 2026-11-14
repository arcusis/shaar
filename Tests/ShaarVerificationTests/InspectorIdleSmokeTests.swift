// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct InspectorIdleSmokeTests {
  @Test func parsesOnlyRepresentableIntegerPollCounts() {
    #expect(InspectorIdleSmoke.pollCallCount(from: 0) == 0)
    #expect(InspectorIdleSmoke.pollCallCount(from: 4) == 4)
    #expect(InspectorIdleSmoke.pollCallCount(from: 5.0) == 5)
    #expect(InspectorIdleSmoke.pollCallCount(from: -2) == nil)
    #expect(InspectorIdleSmoke.pollCallCount(from: -2.0) == nil)
    #expect(InspectorIdleSmoke.pollCallCount(from: 4.5) == nil)
    #expect(InspectorIdleSmoke.pollCallCount(from: Double.infinity) == nil)
    #expect(InspectorIdleSmoke.pollCallCount(from: "4") == nil)
    #expect(InspectorIdleSmoke.pollCallCount(from: nil) == nil)
  }
}
