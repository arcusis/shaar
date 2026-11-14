// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func commandBookmarkChipSparseMatchFocusedBenchmark() throws {
  let profile = BrowserProfile(name: "Personal")
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  let bookmarks = (0..<2_000).map { index in
    BrowserBookmark(
      id: UUID(), profileID: profile.id, parentID: nil,
      title: index >= 1_998 ? "Needle rare result \(index)" : "Common saved page \(index)",
      address: index == 1_998 ? "javascript:alert(1)" : "https://example.com/bookmark-\(index)",
      depth: 0,
      path: "Bookmarks / Page \(index)", isPermanent: false)
  }
  let query = "Needle rare"
  let sources = CommandSources(bookmarks: bookmarks)
  let beforeStart = ContinuousClock.now
  var beforeResults: [CommandResult] = []
  for _ in 0..<10 {
    beforeResults = legacyBookmarkResults(bookmarks, query: query, profileID: profile.id)
  }
  let before = beforeStart.duration(to: .now)

  let afterStart = ContinuousClock.now
  var afterResults: [CommandResult] = []
  for _ in 0..<10 {
    afterResults = CommandLauncher.bookmarkSection(for: query, in: session, sources: sources).results
  }
  let after = afterStart.duration(to: .now)
  print("commandBookmarkChipSparseMatchFocusedBenchmark: before=\(before), after=\(after)")
  #expect(beforeResults == afterResults && afterResults.count == 1)
  #expect(bookmarks[1_998].destination == nil)
  #expect(durationSeconds(after) < durationSeconds(before) * 0.75)
}

private func legacyBookmarkResults(
  _ bookmarks: [BrowserBookmark], query: String, profileID: UUID
) -> [CommandResult] {
  Array(
    bookmarks.lazy
      .filter {
        $0.profileID == profileID && $0.destination != nil
          && CommandText.matches(query, CommandFields.bookmark($0))
      }
      .prefix(CommandLauncher.filteredLimit)
      .map { CommandResult.bookmark($0, subtitle: CommandText.domain(of: $0.destination)) })
}

private func durationSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
