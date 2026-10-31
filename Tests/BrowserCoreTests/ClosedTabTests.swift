// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func reopeningPreservesContextPlacementAndMetadataWithFreshIdentity() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let first = session.open(URL(string: "https://example.com/first")!)!
  let middle = session.open(URL(string: "https://example.com/middle")!)!
  let last = session.open(URL(string: "https://example.com/last")!)!
  let folder = session.addFolder(name: "Accounts", in: space)!
  _ = session.moveTab(middle, from: space, to: space, folderID: folder)
  _ = session.updateTab(middle, url: URL(string: "https://example.com/current")!, title: "Company")
  session.selectTab(middle, in: space)
  let before = session.selectedSpace
  session.closeTab(middle)
  session.closeTab(middle)
  #expect(session.closedTabs.count == 1)
  let entry = try #require(session.closedTabs.first)
  #expect(entry.profileID == before.profileID && entry.spaceID == space)
  #expect(entry.tab == before.selectedTab)
  #expect(entry.index == before.tabs.firstIndex { $0.id == middle })
  _ = session.toggleFolder(folder, in: space)
  let restored = session.reopenClosedTab(middle, in: space)
  let id = try #require(restored)
  #expect(id != middle)
  #expect(session.selectedSpace.selectedTabID == id)
  #expect(session.selectedSpace.tabs.map(\.id) == before.tabs.map { $0.id == middle ? id : $0.id })
  #expect(session.selectedSpace.selectedTab?.title == "Company")
  #expect(session.selectedSpace.selectedTab?.url == before.selectedTab?.url)
  #expect(session.selectedSpace.selectedTab?.folderID == folder)
  #expect(session.selectedSpace.selectedTab?.isPinned == true)
  #expect(session.selectedSpace.folderPath(to: folder).allSatisfy { !$0.isCollapsed })
  session.closeTab(middle)  // A delayed duplicate callback cannot remove the new document.
  #expect(session.selectedSpace.tabs.contains { $0.id == id })
  #expect(session.selectedSpace.tabs.contains { $0.id == first })
  #expect(session.selectedSpace.tabs.contains { $0.id == last })
  #expect(session.closedTabs.isEmpty)
  try session.validate()
}

@Test func closedTabsAreScopedToSpaceEvenWhenProfilesAreShared() throws {
  var session = BrowserSession.fresh()
  let source = session.selectedSpace
  let id = session.open(URL(string: "https://example.com/alpha")!)!
  session.closeTab(id)
  let shared = session.addSpace(name: "Shared", sharingProfile: source.profileID)!
  let before = session
  let rejected = session.reopenClosedTab(id, in: source.id)
  let wrongOwner = session.reopenClosedTab(id, in: shared)
  let cleared = session.clearClosedTabs(in: source.id)
  #expect(rejected == nil && wrongOwner == nil && !cleared)
  #expect(session == before)
  #expect(
    !CommandSearch.results(for: "reopen alpha", in: session).contains {
      if case .reopen = $0.action { return true }
      return false
    })
  session.selectSpace(source.id)
  #expect(
    CommandSearch.results(for: "reopen", in: session).contains {
      $0.action == .reopen(space: source.id, tab: id)
    })
  let reopened = session.reopenClosedTab(id, in: source.id)
  #expect(reopened != nil && session.selectedSpace.profileID == source.profileID)
  try session.validate()
}

@Test func missingFoldersRestoreAtPinnedRootAndRemovedSpacesLoseRecoveryEntries() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let tab = session.open(URL(string: "https://example.com")!)!
  let folder = session.addFolder(name: "Temporary", in: space)!
  _ = session.moveTab(tab, from: space, to: space, folderID: folder)
  session.closeTab(tab)
  _ = session.removeFolder(folder, in: space)
  let restored = session.reopenClosedTab(tab, in: space)
  #expect(restored != nil)
  #expect(session.selectedSpace.selectedTab?.folderID == nil)
  #expect(session.selectedSpace.selectedTab?.isPinned == true)
  session.closeTab(restored!)
  _ = session.removeSpace(space)
  #expect(session.closedTabs.isEmpty)
  try session.validate()
}

@Test func recoveryCapAndClearAffectOnlyTheirOwningSpace() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  for index in 0..<30 {
    let tab = session.open(URL(string: "https://example.com/\(index)")!)!
    session.closeTab(tab)
  }
  #expect(session.recentlyClosedTabs(in: space).count == 25)
  #expect(session.recentlyClosedTabs(in: space).first?.tab.url.path() == "/29")
  #expect(session.recentlyClosedTabs(in: space).last?.tab.url.path() == "/5")
  session.cycleSpace(by: 1)
  let other = session.selectedSpaceID
  let tab = session.open(URL(string: "https://example.com/beta")!)!
  session.closeTab(tab)
  _ = session.clearClosedTabs(in: other)
  #expect(session.closedTabs.count == 25)
  #expect(session.recentlyClosedTabs(in: other).isEmpty)
  #expect(
    try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func v2MigrationPreservesFoldersSelectionsAndOriginalFileUntilSave() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let id = session.open(URL(string: "https://example.com")!)!
  let folder = session.addFolder(name: "Company", in: space)!
  _ = session.moveTab(id, from: space, to: space, folderID: folder)
  _ = session.toggleFolder(folder, in: space)
  var wire = try jsonObject(session)
  wire["version"] = 2
  wire["closedTabs"] = nil
  let original = try JSONSerialization.data(withJSONObject: wire)
  let file = SessionFile(url: root.appending(path: "session.json"))
  try original.write(to: file.url)
  let migrated = try #require(try file.load())
  #expect(
    migrated == session && migrated.version == BrowserSession.currentVersion
      && migrated.closedTabs.isEmpty)
  #expect(try Data(contentsOf: file.url) == original)
  try file.save(migrated)
  #expect(try file.load() == migrated)
}

@Test func malformedRecoveryAndLegacyFilesCannotSilentlyDropEntries() throws {
  var session = BrowserSession.fresh()
  let id = session.open(URL(string: "https://example.com")!)!
  session.closeTab(id)
  let base = try jsonObject(session)
  let entry = try #require((base["closedTabs"] as? [[String: Any]])?.first)
  var invalid: [[String: Any]] = []
  var missing = base
  missing["closedTabs"] = nil
  invalid.append(missing)
  for version in [1, 2] {
    var legacy = base
    legacy["version"] = version
    invalid.append(legacy)
  }
  for change in [
    ["spaceID": UUID().uuidString], ["profileID": UUID().uuidString], ["index": -1],
  ] as [[String: Any]] {
    var record = entry
    for (key, value) in change { record[key] = value }
    var wire = base
    wire["closedTabs"] = [record]
    invalid.append(wire)
  }
  var duplicate = base
  duplicate["closedTabs"] = [entry, entry]
  invalid.append(duplicate)
  var badURL = entry
  var tab = try #require(entry["tab"] as? [String: Any])
  tab["url"] = "javascript:alert(1)"
  badURL["tab"] = tab
  var forbidden = base
  forbidden["closedTabs"] = [badURL]
  invalid.append(forbidden)
  var overCap = base
  overCap["closedTabs"] = (0..<26).map { _ in
    var record = entry
    var snapshot = entry["tab"] as! [String: Any]
    snapshot["id"] = UUID().uuidString
    record["tab"] = snapshot
    return record
  }
  invalid.append(overCap)
  for wire in invalid {
    let data = try JSONSerialization.data(withJSONObject: wire)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserSession.self, from: data) }
  }
}

private func jsonObject(_ session: BrowserSession) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
}
