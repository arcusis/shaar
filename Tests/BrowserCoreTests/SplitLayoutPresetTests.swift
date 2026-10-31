// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func splitPresetsHaveDistinctTitlesAndSymbols() {
  let presets = SplitLayoutPreset.allCases
  #expect(Set(presets.map(\.title)).count == presets.count)
  #expect(Set(presets.map(\.symbol)).count == presets.count)
  #expect(presets.map(\.id) == presets.map(\.rawValue))
  #expect(SplitLayoutPreset.grid.title == "Grid")
  #expect(SplitLayoutPreset.columns.title == "Side by Side")
}

@Test func splitPresetsMatchPaneCount() {
  #expect(SplitLayoutPreset.available(paneCount: 1).isEmpty)
  #expect(SplitLayoutPreset.available(paneCount: 2) == [.columns, .rows])
  #expect(SplitLayoutPreset.available(paneCount: 4) == SplitLayoutPreset.allCases)
  #expect(SplitLayoutPreset.available(paneCount: 5).isEmpty)
  #expect(SplitLayoutPreset.grid.node(for: [UUID(), UUID(), UUID()]) == nil)
}

@Test func gridPresetPlacesFourPanesInTwoRowsAndIsRecognized() throws {
  let ids = (0..<4).map { _ in UUID() }
  let grid = try #require(SplitLayoutPreset.grid.node(for: ids))
  #expect(grid.paneIDs == ids)
  #expect(
    grid
      == .evenly(
        .rows,
        [
          .evenly(.columns, [.pane(ids[0]), .pane(ids[1])]),
          .evenly(.columns, [.pane(ids[2]), .pane(ids[3])]),
        ]))
  #expect(SplitLayoutPreset.matching(grid) == .grid)
  for preset in SplitLayoutPreset.allCases {
    let node = try #require(preset.node(for: ids))
    #expect(SplitLayoutPreset.matching(node) == preset)
  }
}
