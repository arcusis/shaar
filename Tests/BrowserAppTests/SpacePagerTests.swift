// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Testing

@testable import ArcusisBrowser

@Suite
struct SpacePagerTests {
  @Test func snapUsesDistanceVelocityAndBounds() {
    #expect(
      SpacePagerDecision.targetIndex(index: 1, count: 3, offset: -60, velocity: 0, width: 100) == 2)
    #expect(
      SpacePagerDecision.targetIndex(index: 1, count: 3, offset: -20, velocity: -300, width: 100)
        == 2)
    #expect(
      SpacePagerDecision.targetIndex(index: 1, count: 3, offset: 20, velocity: 0, width: 100) == 1)
    #expect(
      SpacePagerDecision.targetIndex(index: 0, count: 3, offset: 100, velocity: 500, width: 100)
        == 0)
    #expect(
      SpacePagerDecision.targetIndex(index: 2, count: 3, offset: -200, velocity: -500, width: 100)
        == 2)
  }

  @Test func rubberBandResistsBeyondEdges() {
    #expect(SpacePagerDecision.rubberBand(50, index: 1, count: 3, width: 100) == 50)
    let first = SpacePagerDecision.rubberBand(100, index: 0, count: 3, width: 100)
    let last = SpacePagerDecision.rubberBand(-100, index: 2, count: 3, width: 100)
    #expect(first > 0 && first < 100)
    #expect(last == -first)
  }
}
