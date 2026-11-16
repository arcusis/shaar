// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation
import Testing

@testable import BrowserCore

@Test func commandOpenPageSetFocusedBenchmark() throws {
  let session = try commandOpenPageSetSession(tabCount: 50_000)
  let expected = legacyOpenPageKeys(in: session)
  #expect(expected.count == 50_012)
  #expect(CommandLauncher.openPageKeys(in: session) == expected)

  _ = legacyOpenPageKeys(in: session)
  _ = CommandLauncher.openPageKeys(in: session)
  let iterations = 5
  var beforeSamples: [Double] = []
  var afterSamples: [Double] = []
  for sample in 0..<9 {
    if sample.isMultiple(of: 2) {
      let beforeStart = threadCPUSeconds()
      for _ in 0..<iterations { _ = legacyOpenPageKeys(in: session) }
      beforeSamples.append(threadCPUSeconds() - beforeStart)
      let afterStart = threadCPUSeconds()
      for _ in 0..<iterations { _ = CommandLauncher.openPageKeys(in: session) }
      afterSamples.append(threadCPUSeconds() - afterStart)
    } else {
      let afterStart = threadCPUSeconds()
      for _ in 0..<iterations { _ = CommandLauncher.openPageKeys(in: session) }
      afterSamples.append(threadCPUSeconds() - afterStart)
      let beforeStart = threadCPUSeconds()
      for _ in 0..<iterations { _ = legacyOpenPageKeys(in: session) }
      beforeSamples.append(threadCPUSeconds() - beforeStart)
    }
  }
  let before = median(beforeSamples)
  let after = median(afterSamples)
  print("commandOpenPageSetFocusedBenchmark: thread CPU before=\(before)s, after=\(after)s")
}

private func median(_ samples: [Double]) -> Double {
  samples.sorted()[samples.count / 2]
}

private func threadCPUSeconds() -> Double {
  var stamp = timespec()
  precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &stamp) == 0)
  return Double(stamp.tv_sec) + Double(stamp.tv_nsec) / 1_000_000_000
}

private func legacyOpenPageKeys(in session: BrowserSession) -> Set<String> {
  let profileID = session.selectedSpace.profileID
  let favoriteIDs = Set(session.favorites(for: profileID).map(\.id))
  let openURLs =
    session.selectedSpace.tabs.map(\.url)
    + session.favoritePages.filter { favoriteIDs.contains($0.favoriteID) }.map(\.tab.url)
  return Set(openURLs.map { CommandLauncher.pageKey($0.absoluteString) })
}

private func commandOpenPageSetSession(tabCount: Int) throws -> BrowserSession {
  let profile = BrowserProfile(name: "Personal")
  let tabs = (0..<tabCount).map { index in
    BrowserTab(url: URL(string: "https://e.test/\(index)")!)
  }
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean, tabs: tabs)
  var session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  for index in 0..<BrowserSession.maximumFavoritesPerProfile {
    _ = session.addFavorite(
      profileID: profile.id, originalURL: URL(string: "https://example.com/favorite-\(index)")!)
  }
  return session
}
