// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import XCTest

@testable import ArcusisBrowser

final class SidebarRevealFramesTests: XCTestCase {
  func testMergeReplacesReportedFramesAndPreservesMissingMeasurements() {
    let selectedID = UUID()
    let replacementID = UUID()
    var frames = SidebarRevealFrames(
      selected: CGRect(x: 1, y: 2, width: 30, height: 20), selectedID: selectedID,
      viewport: CGRect(x: 0, y: 0, width: 300, height: 400))

    frames.merge(
      SidebarRevealFrames(
        selected: CGRect(x: 5, y: 6, width: 40, height: 25), selectedID: replacementID))

    XCTAssertEqual(frames.selected, CGRect(x: 5, y: 6, width: 40, height: 25))
    XCTAssertEqual(frames.selectedID, replacementID)
    XCTAssertEqual(frames.viewport, CGRect(x: 0, y: 0, width: 300, height: 400))

    frames.merge(SidebarRevealFrames(viewport: CGRect(x: 0, y: 0, width: 280, height: 360)))

    XCTAssertEqual(frames.selected, CGRect(x: 5, y: 6, width: 40, height: 25))
    XCTAssertEqual(frames.selectedID, replacementID)
    XCTAssertEqual(frames.viewport, CGRect(x: 0, y: 0, width: 280, height: 360))
  }

  func testEmptyPreferenceValuesDoNotErasePreviouslyReportedFrames() {
    let selectedID = UUID()
    let selected = CGRect(x: 10, y: 12, width: 20, height: 18)
    let viewport = CGRect(x: 2, y: 3, width: 250, height: 350)
    var frames = SidebarRevealFrames(
      selected: selected, selectedID: selectedID, viewport: viewport)

    frames.merge(SidebarRevealFrames())

    XCTAssertEqual(frames.selected, selected)
    XCTAssertEqual(frames.selectedID, selectedID)
    XCTAssertEqual(frames.viewport, viewport)
  }

  func testRevealPreferenceKeysUseTheSameMergeBehavior() {
    assertReductionPreservesValue(SidebarOrdinaryRevealFramesPreferenceKey.self)
    assertReductionPreservesValue(SidebarFavoriteRevealFramesPreferenceKey.self)
    assertReductionPreservesValue(SidebarSpaceRevealFramesPreferenceKey.self)
  }

  private func assertReductionPreservesValue<Key: PreferenceKey>(_: Key.Type)
  where Key.Value == SidebarRevealFrames {
    let selected = CGRect(x: 4, y: 8, width: 24, height: 16)
    let selectedID = UUID()
    var value = SidebarRevealFrames(selected: selected, selectedID: selectedID)

    Key.reduce(value: &value, nextValue: { SidebarRevealFrames() })

    XCTAssertEqual(value.selected, selected)
    XCTAssertEqual(value.selectedID, selectedID)
  }
}
