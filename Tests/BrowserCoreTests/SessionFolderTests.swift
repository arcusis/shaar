import BrowserCore
import Foundation
import Testing

private let legacySession = Data(
  """
  {"version":1,"profiles":[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","name":"Company"}],
  "spaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","profileID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
  "name":"Work","symbol":"briefcase","tint":"ocean","tabs":[{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
  "url":"https://example.com/account","title":"Account","isPinned":true}]}],
  "selectedSpaceID":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"}
  """.utf8)

@Test func v1MigrationPreservesIDsMetadataAndNilSelectionWithoutRewritingInput() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = SessionFile(url: directory.appending(path: "session.json"))
  try legacySession.write(to: file.url)
  let session = try #require(try file.load())
  #expect(session.version == 3)
  #expect(session.profiles[0].id.uuidString == "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
  #expect(session.selectedSpace.id.uuidString == "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")
  #expect(session.selectedSpace.selectedTabID == nil)
  #expect(session.selectedSpace.tabs[0].id.uuidString == "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
  #expect(session.selectedSpace.tabs[0].title == "Account")
  #expect(session.selectedSpace.tabs[0].isPinned)
  #expect(session.selectedSpace.tabs[0].folderID == nil)
  #expect(session.selectedSpace.folders.isEmpty)
  #expect(try Data(contentsOf: file.url) == legacySession)
  try file.save(session)
  #expect(try file.load() == session)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
  #expect(object["version"] as? Int == 3)
}

@Test func v2RejectsMissingFolderFieldsOrphanMembershipAndCycles() throws {
  let profile = BrowserProfile(name: "A")
  let folder = BrowserFolder(name: "Root")
  let child = BrowserFolder(name: "Child", parentID: folder.id)
  let url = URL(string: "https://example.com")!
  for folders in [
    [BrowserFolder(id: folder.id, name: "Root", parentID: folder.id)],
    [BrowserFolder(id: folder.id, name: "Root", parentID: child.id), child],
    [BrowserFolder(name: "Orphan", parentID: UUID())],
    [folder, folder], [BrowserFolder(name: " ")],
  ] {
    let space = BrowserSpace(
      profileID: profile.id, name: "A", symbol: "house", tint: .ocean, folders: folders)
    #expect(throws: SessionError.invalidState) {
      try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    }
  }
  for tab in [
    BrowserTab(url: url, isPinned: false, folderID: folder.id),
    BrowserTab(url: url, isPinned: true, folderID: UUID()),
  ] {
    let space = BrowserSpace(
      profileID: profile.id, name: "A", symbol: "house", tint: .ocean, tabs: [tab],
      folders: [folder])
    #expect(throws: SessionError.invalidState) {
      try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    }
  }
  var wire = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSession.fresh()))
      as? [String: Any])
  var spaces = try #require(wire["spaces"] as? [[String: Any]])
  wire["version"] = 2
  wire["closedTabs"] = nil
  spaces[0]["folders"] = nil
  wire["spaces"] = spaces
  let missing = try JSONSerialization.data(withJSONObject: wire)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserSession.self, from: missing) }
}

@Test func deepFolderTreesUseFiniteTraversalAndValidateEveryParent() throws {
  let profile = BrowserProfile(name: "A")
  var folders: [BrowserFolder] = []
  for index in 0..<2000 {
    folders.append(BrowserFolder(name: "Level \(index)", parentID: folders.last?.id))
  }
  let space = BrowserSpace(
    profileID: profile.id, name: "Deep", symbol: "folder", tint: .forest, folders: folders)
  let session = try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  #expect(session.selectedSpace.pinnedItems().count == 2000)
  #expect(session.selectedSpace.folderPath(to: folders.last!.id).count == 2000)
  #expect(
    try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func collapsedFoldersRetainOrderAndExplicitTabSelectionRevealsAncestors() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let opened = session.open(URL(string: "https://example.com/nested")!)
  let tab = try #require(opened)
  let added = session.addFolder(name: "Projects", in: space)
  let root = try #require(added)
  let nested = session.addFolder(name: "Accounts", in: space, parentID: root)
  let child = try #require(nested)
  let moved = session.moveTab(tab, from: space, to: space, folderID: child)
  #expect(moved)
  #expect(session.selectedSpace.selectedTab?.isPinned == true)
  let before = session.selectedSpace.orderedTabs
  _ = session.toggleFolder(root, in: space)
  #expect(session.selectedSpace.pinnedItems().count == 1)
  #expect(session.selectedSpace.orderedTabs == before)
  #expect(session.selectedSpace.selectedTabID == tab)
  session.selectTab(tab, in: space)
  #expect(session.selectedSpace.folderPath(to: child).allSatisfy { !$0.isCollapsed })
  session.togglePin(tab)
  #expect(session.selectedSpace.selectedTab?.folderID == nil)
  #expect(session.selectedSpace.selectedTab?.isPinned == false)
}

@Test func removingFolderPromotesContainersAndKeepsAllPagesAndSelection() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let first = session.open(URL(string: "https://example.com/first")!)!
  let second = session.open(URL(string: "https://example.com/second")!)!
  let root = session.addFolder(name: "Root", in: space)!
  let child = session.addFolder(name: "Child", in: space, parentID: root)!
  _ = session.moveTab(first, from: space, to: space, folderID: child)
  _ = session.moveTab(second, from: space, to: space, folderID: root)
  let before = session.selectedSpace
  let removed = session.removeFolder(root, in: space)
  #expect(removed)
  #expect(session.selectedSpace.folders == [BrowserFolder(id: child, name: "Child")])
  #expect(session.selectedSpace.tabs.map(\.id) == before.tabs.map(\.id))
  #expect(session.selectedSpace.tabs.map(\.url) == before.tabs.map(\.url))
  #expect(session.selectedSpace.selectedTabID == before.selectedTabID)
  #expect(session.selectedSpace.tabs.first { $0.id == second }?.folderID == nil)
  #expect(session.selectedSpace.tabs.first { $0.id == first }?.folderID == child)
  try session.validate()
}

@Test func folderSubtreesMoveOnlyWithinTheirProfileAndNeverCreateCycles() throws {
  var session = BrowserSession.fresh()
  let source = session.selectedSpace
  let other = session.spaces[1]
  let tab = session.open(URL(string: "https://example.com/account")!)!
  let root = session.addFolder(name: "Root", in: source.id)!
  let child = session.addFolder(name: "Child", in: source.id, parentID: root)!
  _ = session.moveTab(tab, from: source.id, to: source.id, folderID: child)
  let shared = session.addSpace(name: "Shared", sharingProfile: source.profileID)!
  let parent = session.addFolder(name: "Destination", in: shared)!
  session.selectSpace(source.id)
  let before = session
  let rejected = [
    session.moveFolder(root, from: source.id, to: other.id),
    session.moveFolder(root, from: source.id, to: source.id, parentID: child),
    session.moveFolder(child, from: source.id, to: shared, parentID: root),
  ]
  #expect(rejected == [false, false, false])
  #expect(session == before)
  let moved = session.moveFolder(root, from: source.id, to: shared, parentID: parent)
  #expect(moved)
  #expect(session.selectedSpaceID == shared)
  #expect(session.selectedSpace.selectedTabID == tab)
  #expect(session.selectedSpace.folderPath(to: child).map(\.id) == [child, root, parent])
  #expect(session.spaces.first { $0.id == source.id }?.tabs.isEmpty == true)
  #expect(session.spaces[1] == other)
  try session.validate()
  #expect(
    try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func commandSearchFindsCollapsedFolderContentsAndRevealsTheChosenContext() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let tab = session.open(URL(string: "https://example.com/console")!)!
  let root = session.addFolder(name: "Projects", in: space)!
  let child = session.addFolder(name: "Infrastructure", in: space, parentID: root)!
  _ = session.moveTab(tab, from: space, to: space, folderID: child)
  _ = session.toggleFolder(root, in: space)
  let beforeCount = session.spaces.flatMap(\.tabs).count
  let results = CommandSearch.results(for: "Infrastructure", in: session)
  #expect(results.contains { $0.action == .folder(space: space, folder: child) })
  #expect(
    results.contains {
      $0.action == .tab(space: space, tab: tab) && $0.subtitle.contains("Projects / Infrastructure")
    })
  session.cycleSpace(by: 1)
  session.selectFolder(child, in: space)
  #expect(session.selectedSpaceID == space)
  #expect(session.selectedSpace.folderPath(to: child).allSatisfy { !$0.isCollapsed })
  #expect(session.spaces.flatMap(\.tabs).count == beforeCount)
}
