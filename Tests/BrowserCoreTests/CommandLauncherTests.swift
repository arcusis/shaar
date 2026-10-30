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
  #expect(CommandLauncher.domain(of: URL(string: "https://www.apple.com/mac")) == "apple.com")
  #expect(CommandLauncher.domain(of: URL(string: "https://docs.swift.org")) == "docs.swift.org")
  #expect(CommandLauncher.domain(of: nil) == "")
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
