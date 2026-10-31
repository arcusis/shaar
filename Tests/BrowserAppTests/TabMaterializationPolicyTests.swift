// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite
struct TabMaterializationPolicyTests {
  @Test func eagerProbeModeMaterializesSelectedAndBackgroundTabs() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: false)
        == .materialize)
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: false)
        == .materialize)
  }

  @Test func lazyProductionModeMaterializesOnlySelectedTabRegardlessOfPinState() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: true) == .materialize
    )
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: true) == .deferred)
  }

  @Test func loadedTabStaysLiveAcrossSelectionChangesUntilRemoved() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: true) == .materialize
    )
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: true, lazy: true) == .keepLive)
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: true) == .deferred)
  }
}
