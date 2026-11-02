// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func folderMatchesStopAtTheLimitAndKeepTheOpenRow() {
  var session = BrowserSession.fresh()
  for name in ["Archive A", "Archive B", "Archive C"] {
    session.addFolder(name: name, in: session.selectedSpaceID)
  }
  let results = limitedResults(for: "Archive", in: session)
  #expect(results.map(\.title) == ["Archive A", "Archive B", "Archive"])
  #expect(results.last?.symbol == "arrow.up.right")
}

@Test func spaceMatchesStopAtTheLimit() {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  for name in ["Team North", "Team South", "Team East"] {
    session.addSpace(name: name, sharingProfile: profile)
  }
  let results = limitedResults(for: "Team", in: session)
  #expect(results.count == 3)
  #expect(results.dropLast().allSatisfy { $0.subtitle.hasPrefix("Switch space") })
}

@Test func closedTabMatchesStopAtTheLimit() {
  var session = BrowserSession.fresh()
  for path in ["one", "two", "three"] {
    let tab = session.open(URL(string: "https://closed.example/\(path)")!)!
    session.closeTab(tab)
  }
  let results = limitedResults(for: "closed.example", in: session)
  #expect(results.count == 3)
  #expect(results.first?.isOpen == true)
  #expect(results.dropFirst().allSatisfy { $0.symbol == "arrow.uturn.backward" })
}

@Test func bookmarkMatchesStopAtTheLimitAndHideTheirHistory() throws {
  let session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let bookmarks = ["a", "b", "c"].map { bookmark("https://docs.example/\($0)", profile: profile) }
  let history = try ["https://docs.example/a", "https://docs.example/z"].map {
    try visit($0, profile: profile)
  }
  let limited = limitedResults(
    for: "docs.example", in: session, bookmarks: bookmarks, history: history)
  #expect(limited.first?.isOpen == true)
  #expect(limited.dropFirst().map(\.symbol) == ["star", "star"])

  let all = CommandSearch.results(
    for: "docs.example", in: session, bookmarks: bookmarks, history: history)
  #expect(all.filter { $0.symbol == "clock" }.map(\.title) == ["https://docs.example/z"])
}

@Test func historyMatchesStopAtTheLimit() throws {
  let session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let history = try ["a", "b", "c"].map {
    try visit("https://past.example/\($0)", profile: profile)
  }
  let results = limitedResults(for: "past.example", in: session, history: history)
  #expect(results.first?.isOpen == true)
  #expect(results.dropFirst().map(\.symbol) == ["clock", "clock"])
}

private func limitedResults(
  for query: String, in session: BrowserSession, bookmarks: [BrowserBookmark] = [],
  history: [BrowserHistoryEntry] = []
) -> [CommandResult] {
  CommandSearch.results(
    for: query, in: session, bookmarks: bookmarks, history: history, searchEngine: .google,
    limit: 3)
}

private func bookmark(_ address: String, profile: UUID) -> BrowserBookmark {
  BrowserBookmark(
    id: UUID(), profileID: profile, parentID: nil, title: address, address: address, depth: 1,
    path: "Bookmarks bar", isPermanent: false)
}

private func visit(_ address: String, profile: UUID) throws -> BrowserHistoryEntry {
  try BrowserHistoryEntry(
    profileID: profile, payload: ["u": address, "t": address, "n": 1, "v": [1000]])
}
