// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import BrowserCore

@Test func sessionFolderMembershipValidationBenchmark() throws {
  let profile = BrowserProfile(name: "Personal")
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean)
  var session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  let folders = (0..<2_500).map { _ in BrowserFolder(name: "Folder") }
  let tabs = (0..<2_500).map { index in
    BrowserTab(
      url: URL(string: "https://example.com/\(index)")!, isPinned: true,
      folderID: folders.last!.id)
  }
  session.spaces[0].folders = folders
  session.spaces[0].tabs = tabs
  session.spaces[0].selectedTabID = tabs[0].id

  let beforeStart = ContinuousClock.now
  var allTabsBelongToFolder = true
  for _ in 0..<3 {
    for tab in tabs {
      if let folderID = tab.folderID {
        allTabsBelongToFolder = allTabsBelongToFolder
          && folders.contains { $0.id == folderID && $0.isPinned == tab.isPinned }
      }
    }
  }
  #expect(allTabsBelongToFolder)
  let before = beforeStart.duration(to: .now)
  let afterStart = ContinuousClock.now
  for _ in 0..<3 { try session.validate() }
  let after = afterStart.duration(to: .now)
  print("sessionFolderMembershipValidationBenchmark: before=\(before), after=\(after)")
  #expect(after < before * 0.5)
}
