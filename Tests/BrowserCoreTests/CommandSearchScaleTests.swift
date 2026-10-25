import Foundation
import Testing

@testable import BrowserCore

@Test func emptyQueryReturnsFirstTenTabsInOrderAtScale() throws {
  let profile = BrowserProfile(name: "Personal")
  let spaceID = UUID()
  let tabs = (0..<500).map { index in
    BrowserTab(
      id: stableID(index + 1), url: URL(string: "https://example.com/page-\(index)")!,
      title: "Page \(index)")
  }
  let space = BrowserSpace(
    id: spaceID, profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: spaceID)

  let results = CommandSearch.results(for: "", in: session)

  #expect(results.count == 10)
  #expect(results.map(\.action) == tabs.prefix(10).map { .tab(space: spaceID, tab: $0.id) })
}

@Test func lateTitleAddressAndFolderMatchesRemainFindableAtScale() throws {
  let profile = BrowserProfile(name: "Personal")
  let spaceID = UUID()
  let folders = [
    BrowserFolder(id: stableID(9001), name: "Archive"),
    BrowserFolder(id: stableID(9002), name: "Rare folder", parentID: stableID(9001)),
  ]
  var tabs = (0..<400).map { index in
    BrowserTab(
      id: stableID(index + 100), url: URL(string: "https://example.com/page-\(index)")!,
      title: "Page \(index)")
  }
  let titleTab = BrowserTab(
    id: stableID(8001), url: URL(string: "https://example.com/ordinary")!,
    title: "Rare title token")
  let addressTab = BrowserTab(
    id: stableID(8002), url: URL(string: "https://example.com/address-token")!,
    title: "Ordinary page")
  tabs += [titleTab, addressTab]
  let space = BrowserSpace(
    id: spaceID, profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs, folders: folders)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: spaceID)

  #expect(
    CommandSearch.results(for: "Rare title token", in: session).map(\.action)
      == [.tab(space: spaceID, tab: titleTab.id), .open(searchURL("Rare title token"))])
  #expect(
    CommandSearch.results(for: "address-token", in: session).map(\.action)
      == [.tab(space: spaceID, tab: addressTab.id), .open(searchURL("address-token"))])
  #expect(
    CommandSearch.results(for: "Rare folder", in: session).map(\.action)
      == [
        .folder(space: spaceID, folder: stableID(9002)), .open(searchURL("Rare folder")),
      ])
}

@Test func libraryOnlyQueriesPreserveMatchingBookmarkAndHistoryActions() throws {
  let session = singleSpaceSession()
  let profileID = session.selectedSpace.profileID
  let bookmarkID = stableID(7001)
  let bookmark = BrowserBookmark(
    id: bookmarkID, profileID: profileID, parentID: nil, title: "Saved library token",
    address: "https://saved.example.com", depth: 0, path: "Saved library token",
    isPermanent: false)
  let history = try BrowserHistoryEntry(
    profileID: profileID,
    payload: [
      "u": "https://visited.example.com", "t": "Visited library token", "n": 2,
      "v": [1000.0],
    ])

  let bookmarkResults = CommandSearch.results(
    for: "Saved library token", in: session, bookmarks: [bookmark], history: [history])
  let historyResults = CommandSearch.results(
    for: "Visited library token", in: session, bookmarks: [bookmark], history: [history])

  #expect(
    bookmarkResults.map(\.action) == [
      .bookmark(profile: profileID, id: bookmarkID), .open(searchURL("Saved library token")),
    ])
  #expect(
    historyResults.map(\.action) == [
      .history(profile: profileID, address: history.address),
      .open(searchURL("Visited library token")),
    ])
}

@Test func bookmarkDedupAndProfileOwnershipRespectQueryAndSelectedProfile() throws {
  var session = twoProfileSession()
  let profileA = session.selectedSpace.profileID
  let profileB = session.profiles.first { $0.id != profileA }!.id
  let sharedAddress = "https://shared.example.com/page"
  let bookmarkA = BrowserBookmark(
    id: stableID(7101), profileID: profileA, parentID: nil, title: "Bookmark label",
    address: sharedAddress, depth: 0, path: "Bookmark label", isPermanent: false)
  let bookmarkB = BrowserBookmark(
    id: stableID(7102), profileID: profileB, parentID: nil, title: "Profile B label",
    address: "https://profile-b.example.com", depth: 0, path: "Profile B label",
    isPermanent: false)
  let duplicateHistory = try BrowserHistoryEntry(
    profileID: profileA,
    payload: ["u": sharedAddress, "t": "History-only needle", "n": 1, "v": [1000.0]])
  let unmatchedHistory = try BrowserHistoryEntry(
    profileID: profileA,
    payload: [
      "u": "https://other.example.com", "t": "History-only needle", "n": 1,
      "v": [2000.0],
    ])
  let bookmarks = [bookmarkA, bookmarkB]
  let history = [duplicateHistory, unmatchedHistory]

  let historyTitleResults = CommandSearch.results(
    for: "History-only needle", in: session, bookmarks: bookmarks, history: history)
  #expect(
    historyTitleResults.map(\.action)
      == [
        .history(profile: profileA, address: duplicateHistory.address),
        .history(profile: profileA, address: unmatchedHistory.address),
        .open(searchURL("History-only needle")),
      ])
  #expect(
    !historyTitleResults.contains { $0.action == .bookmark(profile: profileB, id: bookmarkB.id) })

  let bookmarkTitleResults = CommandSearch.results(
    for: "Bookmark label", in: session, bookmarks: bookmarks, history: history)
  #expect(
    bookmarkTitleResults.map(\.action)
      == [.bookmark(profile: profileA, id: bookmarkA.id), .open(searchURL("Bookmark label"))])

  session.selectSpace(session.spaces.first { $0.profileID == profileB }!.id)
  let profileBResults = CommandSearch.results(
    for: "Profile B label", in: session, bookmarks: bookmarks, history: history)
  #expect(
    profileBResults.map(\.action)
      == [.bookmark(profile: profileB, id: bookmarkB.id), .open(searchURL("Profile B label"))])
}

@Test func invalidNavigationInputHasNoOpenActionAndValidInputKeepsOpenSlotLast() throws {
  let profile = BrowserProfile(name: "Personal")
  let spaceID = UUID()
  let tabs = (0..<20).map { index in
    BrowserTab(
      id: stableID(index + 2000), url: URL(string: "https://example.com/\(index)")!,
      title: "javascript:alert(1)")
  }
  let space = BrowserSpace(
    id: spaceID, profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: spaceID)

  let invalid = CommandSearch.results(for: "javascript:alert(1)", in: session)
  let valid = CommandSearch.results(for: "ordinary search", in: session)

  #expect(invalid.count == 10)
  #expect(invalid.map(\.action) == tabs.prefix(10).map { .tab(space: spaceID, tab: $0.id) })
  #expect(valid.count == 1)
  #expect(valid.last?.action == .open(searchURL("ordinary search")))
}

private func singleSpaceSession() -> BrowserSession {
  let profile = BrowserProfile(name: "Personal")
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean)
  return try! BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
}

private func twoProfileSession() -> BrowserSession {
  let profileA = BrowserProfile(name: "A")
  let profileB = BrowserProfile(name: "B")
  let selected = BrowserSpace(
    profileID: profileA.id, name: "Selected", symbol: "house", tint: .ocean)
  let shared = BrowserSpace(
    profileID: profileA.id, name: "Shared", symbol: "square.stack", tint: .forest)
  let distinct = BrowserSpace(
    profileID: profileB.id, name: "Distinct", symbol: "briefcase", tint: .rose)
  return try! BrowserSession(
    profiles: [profileA, profileB], spaces: [selected, shared, distinct],
    selectedSpaceID: selected.id)
}

private func searchURL(_ query: String) -> URL {
  var components = URLComponents(string: "https://www.google.com/search")!
  components.queryItems = [URLQueryItem(name: "q", value: query)]
  return components.url!
}

private func stableID(_ suffix: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix))!
}

@Test func selectedSpaceSaturationStopsBeforeLaterSpacesInOutputOrder() throws {
  let profile = BrowserProfile(name: "Personal")
  let selectedID = stableID(9100)
  let laterID = stableID(9200)
  let selectedTabs = (0..<20).map { index in
    BrowserTab(
      id: stableID(index + 9101), url: URL(string: "https://selected.example/page-\(index)")!,
      title: "Selected \(index)")
  }
  let laterTabs = (0..<20).map { index in
    BrowserTab(
      id: stableID(index + 9201), url: URL(string: "https://later.example/page-\(index)")!,
      title: "Later \(index)")
  }
  let selected = BrowserSpace(
    id: selectedID, profileID: profile.id, name: "Selected", symbol: "house", tint: .ocean,
    tabs: selectedTabs)
  let later = BrowserSpace(
    id: laterID, profileID: profile.id, name: "Later", symbol: "square.stack", tint: .forest,
    tabs: laterTabs)
  let session = try BrowserSession(
    profiles: [profile], spaces: [later, selected], selectedSpaceID: selectedID)

  let results = CommandSearch.results(for: "", in: session)

  #expect(
    results.map(\.action) == selectedTabs.prefix(10).map { .tab(space: selectedID, tab: $0.id) })
}

@Test func nineResultsReserveFinalOpenSlot() throws {
  let profile = BrowserProfile(name: "Personal")
  let spaceID = stableID(9300)
  let tabs = (0..<30).map { index in
    BrowserTab(
      id: stableID(index + 9301), url: URL(string: "https://example.com/page-\(index)")!,
      title: "Example domain page \(index)")
  }
  let space = BrowserSpace(
    id: spaceID, profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: spaceID)

  let results = CommandSearch.results(for: "Example domain", in: session)

  #expect(results.count == 10)
  #expect(
    results.dropLast().map(\.action) == tabs.prefix(9).map { .tab(space: spaceID, tab: $0.id) })
  #expect(results.last?.action == .open(searchURL("Example domain")))
}
