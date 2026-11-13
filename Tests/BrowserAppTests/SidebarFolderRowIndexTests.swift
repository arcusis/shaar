// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func sidebarFolderRowLookupFocusedBenchmark() {
  let folderIDs = (0..<300).map { _ in UUID() }
  let folders = folderIDs.enumerated().map { index, id in
    BrowserFolder(
      id: id, name: "Folder \(index)", parentID: index == 0 ? nil : folderIDs[index - 1])
  }
  let tabs = (0..<3_000).map { index in
    BrowserTab(
      url: URL(string: "https://example.com/\(index)")!, title: "Tab \(index)",
      folderID: folderIDs[index % folderIDs.count])
  }
  let space = BrowserSpace(
    profileID: UUID(), name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs, folders: folders)
  let selectedFolderID = folderIDs.last

  let start = ContinuousClock.now
  let index = SidebarFolderRowIndex(space: space, activeFolderID: selectedFolderID)
  var checksum = 0
  for _ in 0..<10 {
    for folder in folders {
      checksum += (index.isActive(folder.id) ? 1 : 0)
        + (index.hasContents(folder.id) ? 1 : 0) + index.pathLabel(to: folder.id).count
    }
  }
  print("sidebarFolderRowLookupFocusedBenchmark: \(start.duration(to: .now))")
  #expect(checksum > 0)
  for folder in folders {
    #expect(index.isActive(folder.id) == space.folderPath(to: selectedFolderID).contains { $0.id == folder.id })
    #expect(index.hasContents(folder.id) == (space.tabs.contains { $0.folderID == folder.id }
      || space.folders.contains { $0.parentID == folder.id }))
    #expect(index.pathLabel(to: folder.id) == space.folderPath(to: folder.id).reversed().map(\.name).joined(separator: " / "))
  }
}
