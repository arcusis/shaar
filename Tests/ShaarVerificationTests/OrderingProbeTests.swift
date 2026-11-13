// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite("Ordering probe Boolean fields")
struct OrderingProbeTests {
  @Test func pinAndActiveFlagsAcceptOnlyBooleanValues() {
    #expect(OrderingProbe.pinnedFlag(true))
    #expect(!OrderingProbe.pinnedFlag(false))
    #expect(!OrderingProbe.pinnedFlag(1))
    #expect(!OrderingProbe.pinnedFlag(0))
    #expect(!OrderingProbe.pinnedFlag("true"))
    #expect(!OrderingProbe.pinnedFlag(nil))
  }
}
