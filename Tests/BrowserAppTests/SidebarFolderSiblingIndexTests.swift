// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func sidebarFolderSiblingLookupFocusedBenchmark() {
  let parentIDs = (0..<50).map { _ in UUID() }
  let folders = (0..<3_000).map { index in
    BrowserFolder(
      id: UUID(), name: "Folder \(index)",
      parentID: parentIDs[index % parentIDs.count],
      isPinned: index.isMultiple(of: 2))
  }
  let rows = Array(folders.prefix(500))
  let index = SidebarFolderSiblingIndex(folders: folders)
  for folder in rows {
    let expected = folders.filter {
      $0.parentID == folder.parentID && $0.isPinned == folder.isPinned
    }
    #expect(index.siblings(of: folder).map(\.id) == expected.map(\.id))
  }

  let baselineStart = ContinuousClock.now
  var baselineCount = 0
  for _ in 0..<10 {
    for folder in rows {
      let matchingSiblings = folders.filter { candidate in
        candidate.parentID == folder.parentID && candidate.isPinned == folder.isPinned
      }
      baselineCount += matchingSiblings.count
    }
  }
  let baselineDuration = baselineStart.duration(to: .now)

  let indexedStart = ContinuousClock.now
  var indexedCount = 0
  for _ in 0..<10 {
    for folder in rows { indexedCount += index.siblings(of: folder).count }
  }
  let indexedDuration = indexedStart.duration(to: .now)

  #expect(baselineCount == indexedCount)
  print("sidebarFolderSiblingLookupFocusedBenchmark baseline: \(baselineDuration)")
  print("sidebarFolderSiblingLookupFocusedBenchmark indexed: \(indexedDuration)")
}
