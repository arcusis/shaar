// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func emptyQueryShowsSuggestionSectionsInOrder() throws {
  var fixture = try LauncherFixture()
  fixture.session.closeTab(fixture.closedTabID)

  let sections = CommandLauncher.sections(
    for: "", filter: nil, in: fixture.session, sources: fixture.sources)

  #expect(
    sections.map(\.title) == ["Open Tabs", "Favorites & Pinned", "Recently Closed", "Most Visited"])
  #expect(
    sections[0].results.map(\.action)
      == [.tab(space: fixture.spaceID, tab: fixture.openTabID)])
  #expect(
    sections[1].results.map(\.action)
      == [
        .favorite(profile: fixture.profileID, id: fixture.favoriteID),
        .tab(space: fixture.spaceID, tab: fixture.pinnedTabID),
      ])
  #expect(
    sections[2].results.map(\.action)
      == [.reopen(space: fixture.spaceID, tab: fixture.closedTabID)])
  #expect(sections[0].results.first?.subtitle == "open.example")
  #expect(sections.results.allSatisfy { !$0.isOpen })
}

@Test func mostVisitedRanksByVisitsAndSkipsOpenPagesAndOtherProfiles() throws {
  let fixture = try LauncherFixture()
  let other = UUID()
  let history = [
    try entry("https://rare.example/", visits: 2, profile: fixture.profileID),
    try entry("https://www.frequent.example/", visits: 40, profile: fixture.profileID),
    try entry("https://open.example/", visits: 90, profile: fixture.profileID),
    try entry("https://other-profile.example/", visits: 99, profile: other),
  ]

  let results = CommandLauncher.mostVisited(in: fixture.session, history: history)

  #expect(
    results.map(\.action)
      == [
        .history(profile: fixture.profileID, address: "https://www.frequent.example/"),
        .history(profile: fixture.profileID, address: "https://rare.example/"),
      ])
  #expect(results.first?.subtitle == "frequent.example")
}

@Test func emptySpaceStillSuggestsFavoritesClosedTabsAndHistory() throws {
  var fixture = try LauncherFixture()
  for id in [fixture.openTabID, fixture.pinnedTabID, fixture.closedTabID] {
    fixture.session.closeTab(id)
  }

  let sections = CommandLauncher.sections(
    for: "  ", filter: nil, in: fixture.session, sources: fixture.sources)

  #expect(sections.map(\.title) == ["Favorites & Pinned", "Recently Closed", "Most Visited"])
}

@Test func typedQueryKeepsHitsThenActionsThenOpenWithinTenRows() throws {
  let fixture = try LauncherFixture()
  var sources = fixture.sources
  sources.commands = (0..<5).map {
    LauncherCommand(id: "open\($0)", title: "Open View \($0)", detail: "Tabs", symbol: "square")
  }

  let sections = CommandLauncher.sections(
    for: "open", filter: nil, in: fixture.session, sources: sources)

  #expect(sections.map(\.id) == ["top-hits", "actions", "open"])
  #expect(sections[1].results.count == CommandLauncher.searchActionLimit)
  #expect(sections.results.count <= 10)
  #expect(sections.results.last?.isOpen == true)
  #expect(sections.headerCount == 1)
  #expect(sections[0].results.first?.action == .tab(space: fixture.spaceID, tab: fixture.openTabID))
}

@Test func typedQueryRanksLikeCommandSearchWithoutActions() throws {
  let fixture = try LauncherFixture()

  let sections = CommandLauncher.sections(
    for: "example", filter: nil, in: fixture.session, sources: fixture.sources)

  #expect(
    sections.results
      == CommandSearch.results(
        for: "example", in: fixture.session, bookmarks: fixture.sources.bookmarks,
        history: fixture.sources.history))
}

@Test func chipsNarrowResultsToOneKind() throws {
  var fixture = try LauncherFixture()
  fixture.session.closeTab(fixture.closedTabID)
  func actions(_ filter: CommandFilter, _ query: String = "") -> [CommandAction] {
    CommandLauncher.sections(
      for: query, filter: filter, in: fixture.session, sources: fixture.sources
    ).results.map(\.action)
  }

  #expect(
    actions(.tabs).allSatisfy {
      switch $0 {
      case .tab, .favorite, .reopen: true
      default: false
      }
    })
  #expect(actions(.tabs, "pinned") == [.tab(space: fixture.spaceID, tab: fixture.pinnedTabID)])
  #expect(
    actions(.history)
      == fixture.sources.history.map { .history(profile: fixture.profileID, address: $0.address) })
  #expect(actions(.bookmarks) == [.bookmark(profile: fixture.profileID, id: fixture.bookmarkID)])
  #expect(actions(.bookmarks, "missing").isEmpty)
  #expect(actions(.actions) == [.command("newSpace"), .command("settings")])
  #expect(actions(.actions, "set") == [.command("settings")])
}

@Test func tabsChipListsOtherSpacesAfterTheSelectedOne() throws {
  let fixture = try LauncherFixture(extraSpace: true)

  let section = try #require(
    CommandLauncher.sections(
      for: "", filter: .tabs, in: fixture.session, sources: fixture.sources
    ).first)

  #expect(
    section.results.last?.action == .tab(space: fixture.otherSpaceID, tab: fixture.otherTabID))
  #expect(section.results.last?.subtitle == "Elsewhere · elsewhere.example")
}

@Test func actionsMatchWordPrefixesOnly() {
  let command = LauncherCommand(
    id: "splitView", title: "Split View", detail: "Tabs", symbol: "square")

  #expect(command.matches(""))
  #expect(command.matches("spl"))
  #expect(command.matches("view"))
  #expect(command.matches("split v"))
  #expect(!command.matches("iew"))
}

@Test func filterCycleVisitsEveryChipAndWraps() {
  #expect(CommandFilter.cycled(from: nil, by: 1) == .tabs)
  #expect(CommandFilter.cycled(from: .actions, by: 1) == nil)
  #expect(CommandFilter.cycled(from: nil, by: -1) == .actions)
  #expect(CommandFilter.cycled(from: .history, by: -1) == .tabs)
  #expect(CommandFilter.allCases.map(\.title) == ["Tabs", "History", "Bookmarks", "Actions"])
}

@Test func domainDropsLeadingWWW() {
  #expect(CommandText.domain(of: URL(string: "https://www.apple.com/mac")) == "apple.com")
  #expect(CommandText.domain(of: URL(string: "https://docs.swift.org")) == "docs.swift.org")
  #expect(CommandText.domain(of: nil) == "")
}

@Test func typedSearchAndChipsShowTheSameDomain() throws {
  var fixture = try LauncherFixture()
  let opened = fixture.session.open(URL(string: "https://www.domain-check.example/a")!)
  let tab = try #require(opened)

  let typed = CommandLauncher.sections(
    for: "domain-check", filter: nil, in: fixture.session, sources: fixture.sources)
  let chip = CommandLauncher.sections(
    for: "domain-check", filter: .tabs, in: fixture.session, sources: fixture.sources)

  let typedTab = try #require(
    typed.results.first { $0.action == .tab(space: fixture.spaceID, tab: tab) })
  #expect(typedTab.subtitle == "Main · domain-check.example")
  #expect(chip.results.first?.subtitle == "domain-check.example")
}

@Test func plainWordsWithNoHitsKeepWebSearchAsTheDefaultRow() throws {
  let fixture = try LauncherFixture()

  let sections = CommandLauncher.sections(
    for: "new", filter: nil, in: fixture.session, sources: fixture.sources)

  #expect(sections.map(\.id) == ["open", "actions"])
  #expect(sections.results.first?.isOpen == true)
  #expect(sections.results.map(\.action).contains(.command("newSpace")))
}

@Test func emptyStateCapsFavoritesAndPinnedTabsSeparately() throws {
  var fixture = try LauncherFixture()
  for index in 0..<CommandLauncher.suggestedFavoriteLimit {
    fixture.session.addFavorite(
      profileID: fixture.profileID, originalURL: URL(string: "https://fav-\(index).example")!,
      title: "Favorite \(index)")
  }

  let sections = CommandLauncher.sections(
    for: "", filter: nil, in: fixture.session, sources: fixture.sources)
  let favorites = try #require(sections.first { $0.id == "favorites" })

  #expect(favorites.results.count == CommandLauncher.suggestedFavoriteLimit + 1)
  #expect(favorites.results.last?.action == .tab(space: fixture.spaceID, tab: fixture.pinnedTabID))
}

@Test func tabsChipListsRecentlyClosedUpToTheFilteredLimit() throws {
  var fixture = try LauncherFixture()
  for index in 0..<5 {
    let opened = fixture.session.open(URL(string: "https://gone-\(index).example")!)
    let id = try #require(opened)
    fixture.session.closeTab(id)
  }

  let sections = CommandLauncher.sections(
    for: "gone", filter: .tabs, in: fixture.session, sources: fixture.sources)

  #expect(sections.first { $0.id == "recently-closed" }?.results.count == 5)
}

@Test func duplicateFavoritePagesDoNotTrapSearch() throws {
  var fixture = try LauncherFixture()
  let page = try #require(fixture.session.favoritePages.first)
  fixture.session.favoritePages.append(page)

  let results = CommandSearch.results(for: "favorite", in: fixture.session)

  #expect(
    results.contains { $0.action == .favorite(profile: fixture.profileID, id: fixture.favoriteID) })
}

@Test func mostVisitedKeepsTheTopFewInRankOrder() throws {
  let fixture = try LauncherFixture()
  let history = try (1...9).map {
    try entry("https://visits-\($0).example/", visits: $0 * 7 % 10, profile: fixture.profileID)
  }

  let results = CommandLauncher.mostVisited(in: fixture.session, history: history)
  let expected = history.sorted { $0.visitCount > $1.visitCount }
    .prefix(CommandLauncher.mostVisitedLimit)
    .map { CommandAction.history(profile: fixture.profileID, address: $0.address) }

  #expect(results.map(\.action) == expected)
}

@Test func selectionFollowsItsRowAndClampsWhenTheRowIsGone() {
  let rows = ["a", "b", "c"].map(row)
  var selection = CommandSelection(index: 1, in: rows)
  #expect(selection.id == row("b").id)

  #expect(selection.index(in: [row("x")] + rows) == 2)
  #expect(selection.index(in: [row("a")]) == 0)
  selection = CommandSelection(index: 9, in: rows)
  #expect(selection.index(in: rows) == 2)
  #expect(CommandSelection(index: 0, in: []).index(in: []) == 0)
}

private func row(_ name: String) -> CommandResult {
  .command(LauncherCommand(id: name, title: name, detail: "", symbol: "square"))
}

private struct LauncherFixture {
  let profileID = UUID()
  let spaceID = UUID()
  let openTabID = UUID()
  let pinnedTabID = UUID()
  let closedTabID = UUID()
  let otherSpaceID = UUID()
  let otherTabID = UUID()
  let bookmarkID = UUID()
  let favoriteID = UUID()
  var session: BrowserSession
  let sources: CommandSources

  init(extraSpace: Bool = false) throws {
    let profile = BrowserProfile(id: profileID, name: "Personal")
    let space = BrowserSpace(
      id: spaceID, profileID: profileID, name: "Main", symbol: "house", tint: .ocean,
      tabs: [
        BrowserTab(
          id: pinnedTabID, url: URL(string: "https://pinned.example")!, title: "Pinned",
          isPinned: true),
        BrowserTab(id: openTabID, url: URL(string: "https://open.example")!, title: "Open page"),
        BrowserTab(id: closedTabID, url: URL(string: "https://closed.example")!, title: "Closed"),
      ])
    let other = BrowserSpace(
      id: otherSpaceID, profileID: profileID, name: "Elsewhere", symbol: "globe", tint: .rose,
      tabs: [
        BrowserTab(id: otherTabID, url: URL(string: "https://elsewhere.example")!, title: "Other")
      ])
    session = try BrowserSession(
      profiles: [profile], spaces: extraSpace ? [other, space] : [space], selectedSpaceID: spaceID)
    session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example")!,
      title: "Favorite", id: favoriteID)
    sources = CommandSources(
      bookmarks: [
        BrowserBookmark(
          id: bookmarkID, profileID: profileID, parentID: nil, title: "Docs",
          address: "https://docs.example/", depth: 1, path: "Bookmarks bar", isPermanent: false)
      ],
      history: [try entry("https://history.example/", visits: 3, profile: profileID)],
      commands: [
        LauncherCommand(id: "newSpace", title: "New space", detail: "Spaces", symbol: "plus"),
        LauncherCommand(id: "settings", title: "Settings", detail: "App · ⌘,", symbol: "gear"),
      ])
  }
}

private func entry(_ address: String, visits: Int, profile: UUID) throws -> BrowserHistoryEntry {
  try BrowserHistoryEntry(
    profileID: profile, payload: ["u": address, "t": address, "n": visits, "v": [1000]])
}
