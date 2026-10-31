// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

private func workspaceFixture() throws -> BrowserSession {
  var session = BrowserSession.fresh()
  let root = session.selectedSpaceID
  let pin = session.open(URL(string: "https://example.com/pinned")!)!
  session.togglePin(pin)
  let folder = session.addFolder(name: "Tools", in: root)!
  _ = session.moveTab(pin, from: root, to: root, folderID: folder)
  _ = session.toggleFolder(folder, in: root)
  let ordinary = session.open(URL(string: "https://example.com/ordinary")!)!
  let closed = session.open(URL(string: "https://example.com/closed")!)!
  session.closeTab(closed)
  session.selectTab(ordinary, in: root)
  return session
}

@Test func workspaceMigrationPreservesLegacyBytesIDsAndRecoveryUntilExplicitSave() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let legacy = SessionFile(url: directory.appending(path: "session.json"))
  let original = try workspaceFixture()
  try legacy.save(original)
  let bytes = try Data(contentsOf: legacy.url)
  let file = WorkspaceFile(
    url: directory.appending(path: "workspace.json"), legacySessionURL: legacy.url)
  var workspace = try #require(try file.load())
  #expect(workspace.windows[0].session == original)
  #expect(try Data(contentsOf: legacy.url) == bytes)
  #expect(!FileManager.default.fileExists(atPath: file.url.path))
  let second = try workspace.addWindow(from: workspace.windows[0].id)
  try file.save(workspace)
  #expect(try file.load() == workspace)
  #expect(try Data(contentsOf: legacy.url) == bytes)
  #expect(workspace.focusedWindowID == second)
  let mode =
    try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
  #expect(mode?.intValue == 0o600)
  try legacy.save(.fresh())
  #expect(try file.load() == workspace)
}

@Test func newWindowsShareDefinitionsAndProfilesWithFreshPinInstancesOnly() throws {
  let initial = try workspaceFixture()
  var workspace = try BrowserWorkspace(session: initial)
  let first = workspace.windows[0]
  let next = try workspace.addWindow(from: first.id)
  let second = try #require(workspace.window(next))
  #expect(second.session.profiles == initial.profiles)
  #expect(second.session.spaces.map(\.id) == initial.spaces.map(\.id))
  #expect(second.session.spaces.flatMap(\.tabs).allSatisfy { $0.isPinned })
  #expect(second.session.spaces.allSatisfy { $0.selectedTabID == nil })
  #expect(second.session.closedTabs.isEmpty)
  #expect(
    Set(second.session.spaces.flatMap(\.tabs).map(\.id)).isDisjoint(
      with: initial.spaces.flatMap(\.tabs).map(\.id)))
  #expect(second.pins.map(\.pinID) == first.pins.map(\.pinID))
  #expect(workspace.windows[0].session == initial)
  try workspace.validate()
}

@Test func workspaceLegacyV1AndV2MigrationPreservesIDsAndNilSelection() throws {
  for version in [1, 2] {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let profile = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    let space = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    let tab = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    var record: [String: Any] = [
      "id": space, "profileID": profile, "name": "Legacy", "symbol": "house", "tint": "ocean",
      "tabs": [
        ["id": tab, "url": "https://example.com/legacy", "title": "Legacy pin", "isPinned": true]
      ],
    ]
    if version == 2 { record["folders"] = [] }
    let wire: [String: Any] = [
      "version": version, "profiles": [["id": profile, "name": "Account"]],
      "spaces": [record], "selectedSpaceID": space,
    ]
    let file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
    let bytes = try JSONSerialization.data(withJSONObject: wire)
    try bytes.write(to: file.legacySessionURL)
    let migrated = try #require(try file.load())
    #expect(migrated.windows[0].session.version == BrowserSession.currentVersion)
    #expect(migrated.windows[0].session.selectedSpace.selectedTabID == nil)
    #expect(migrated.windows[0].session.profiles[0].id.uuidString == profile)
    #expect(migrated.windows[0].session.selectedSpace.id.uuidString == space)
    #expect(migrated.windows[0].session.selectedSpace.tabs[0].id.uuidString == tab)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    try file.save(migrated)
    #expect(try file.load() == migrated)
    #expect(try Data(contentsOf: file.legacySessionURL) == bytes)
  }
}

@Test func pinnedNavigationStaysWindowLocalAndNewWindowsUseOriginalPinAddress() throws {
  var workspace = try BrowserWorkspace(session: workspaceFixture())
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  let secondBefore = workspace.window(secondID)!
  let definition = workspace.catalog.spaces.flatMap(\.tabs)[0]
  var first = workspace.window(firstID)!.session
  let pin = first.spaces.flatMap(\.tabs).first(where: \.isPinned)!
  _ = first.updateTab(
    pin.id, url: URL(string: "https://example.com/active-navigation")!, title: "Current document")
  try workspace.updateWindow(firstID, session: first)
  #expect(workspace.catalog.spaces.flatMap(\.tabs)[0] == definition)
  #expect(workspace.window(secondID) == secondBefore)
  let thirdID = try workspace.addWindow(from: firstID)
  #expect(workspace.window(thirdID)!.session.spaces.flatMap(\.tabs)[0].url == definition.url)
  #expect(workspace.window(firstID)!.session == first)
}

@Test func sharedPinRemovalRetainsOtherWindowsLiveDocumentAndSelection() throws {
  var workspace = try BrowserWorkspace(session: workspaceFixture())
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  var second = workspace.window(secondID)!.session
  let secondPin = second.spaces.flatMap(\.tabs)[0]
  second.selectTab(secondPin.id, in: second.spaces[0].id)
  _ = second.updateTab(
    secondPin.id, url: URL(string: "https://example.com/unsaved-view")!, title: "Retained")
  try workspace.updateWindow(secondID, session: second)
  var first = workspace.window(firstID)!.session
  first.closeTab(first.spaces.flatMap(\.tabs).first(where: \.isPinned)!.id)
  try workspace.updateWindow(firstID, session: first)
  let retained = workspace.window(secondID)!.session
  #expect(workspace.catalog.spaces.flatMap(\.tabs).isEmpty)
  #expect(workspace.window(secondID)!.pins.isEmpty)
  #expect(retained.selectedSpace.selectedTabID == secondPin.id)
  #expect(
    retained.selectedSpace.selectedTab?.url.absoluteString == "https://example.com/unsaved-view")
  #expect(retained.selectedSpace.selectedTab?.isPinned == false)
  #expect(retained.selectedSpace.selectedTab?.folderID == nil)
  #expect(retained.closedTabs.isEmpty)
  #expect(workspace.window(firstID)!.session.closedTabs.count == first.closedTabs.count)
}

@Test func sharedPinMovesAndMetadataPreserveOtherWindowsIDsAndLocalFolderCollapse() throws {
  var initial = try workspaceFixture()
  let source = initial.spaces[0].id
  let shared = initial.addSpace(name: "Shared", sharingProfile: initial.spaces[0].profileID)!
  initial.selectSpace(source)
  var workspace = try BrowserWorkspace(session: initial)
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  var second = workspace.window(secondID)!.session
  let instance = second.spaces[0].tabs[0]
  second.selectTab(instance.id, in: source)
  _ = second.toggleFolder(second.spaces[0].folders[0].id, in: source)
  try workspace.updateWindow(secondID, session: second)
  var first = workspace.window(firstID)!.session
  _ = first.updateSpace(source, name: "Renamed", tint: .rose)
  try workspace.updateWindow(firstID, session: first)
  #expect(workspace.window(secondID)!.session.spaces[0].folders[0].isCollapsed)
  let original = first.spaces[0].tabs.first(where: \.isPinned)!
  let moved = first.moveTab(original.id, from: source, to: shared, pinned: true)
  #expect(moved)
  try workspace.updateWindow(firstID, session: first)
  let projected = workspace.window(secondID)!.session
  #expect(projected.selectedSpaceID == shared)
  #expect(projected.selectedSpace.selectedTabID == instance.id)
  #expect(projected.selectedSpace.tabs[0].id == instance.id)
  #expect(projected.spaces[0].name == "Renamed" && projected.spaces[0].tint == .rose)
  #expect(projected.selectedSpace.profileID == initial.spaces[0].profileID)
}

@Test func conflictingLiveArchivedAndProfileOwnershipIsRejectedWithoutMutation() throws {
  var workspace = try BrowserWorkspace(session: workspaceFixture())
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  let before = workspace
  var second = workspace.window(secondID)!.session
  second.spaces[0].tabs.append(workspace.windows[0].session.spaces[0].tabs.first { !$0.isPinned }!)
  #expect(throws: WorkspaceError.self) { try workspace.updateWindow(secondID, session: second) }
  #expect(workspace == before)
  second = workspace.window(secondID)!.session
  second.closedTabs = workspace.windows[0].session.closedTabs
  #expect(throws: WorkspaceError.self) { try workspace.updateWindow(secondID, session: second) }
  #expect(workspace == before)
  var changed = workspace.windows[0].session
  changed.spaces[0] = BrowserSpace(
    id: changed.spaces[0].id, profileID: changed.spaces[1].profileID, name: "Foreign",
    symbol: "house", tint: .ocean, tabs: changed.spaces[0].tabs, folders: changed.spaces[0].folders)
  changed.closedTabs = []
  #expect(throws: WorkspaceError.self) { try workspace.updateWindow(firstID, session: changed) }
  #expect(workspace == before)
  #expect(throws: WorkspaceError.self) { try workspace.updateWindow(UUID(), session: changed) }
  #expect(workspace == before)
}

@Test func sharedFolderMovesPreserveAnotherWindowsLocalCollapseState() throws {
  var initial = try workspaceFixture()
  let source = initial.spaces[0].id
  let folder = initial.spaces[0].folders[0].id
  let shared = initial.addSpace(name: "Shared folder", sharingProfile: initial.spaces[0].profileID)!
  var workspace = try BrowserWorkspace(session: initial)
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  var second = workspace.window(secondID)!.session
  _ = second.toggleFolder(folder, in: source)
  try workspace.updateWindow(secondID, session: second)
  var first = workspace.window(firstID)!.session
  let moved = first.moveFolder(folder, from: source, to: shared)
  #expect(moved)
  try workspace.updateWindow(firstID, session: first)
  let destination = workspace.window(secondID)!.session.spaces.first { $0.id == shared }!
  #expect(destination.folders[0].id == folder && destination.folders[0].isCollapsed)
  #expect(destination.tabs[0].folderID == folder)
}

@Test func lastWindowClosurePreservesCatalogAndReopeningDoesNotRestoreClosedLivePages() throws {
  var workspace = try BrowserWorkspace(session: workspaceFixture())
  let catalog = workspace.catalog
  try workspace.removeWindow(workspace.windows[0].id)
  #expect(workspace.windows.isEmpty && workspace.focusedWindowID == nil)
  #expect(workspace.catalog == catalog)
  workspace = try JSONDecoder().decode(BrowserWorkspace.self, from: JSONEncoder().encode(workspace))
  let reopened = try workspace.addWindow()
  #expect(workspace.window(reopened)!.session.spaces.flatMap(\.tabs).allSatisfy { $0.isPinned })
  #expect(workspace.window(reopened)!.session.closedTabs.isEmpty)
  #expect(workspace.catalog == catalog)
}

@Test func futureMalformedAndAliasedWorkspaceFilesNeverFallBackToLegacy() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let legacy = SessionFile(url: directory.appending(path: "session.json"))
  try legacy.save(workspaceFixture())
  let file = WorkspaceFile(
    url: directory.appending(path: "workspace.json"), legacySessionURL: legacy.url)
  let workspace = try BrowserWorkspace(session: workspaceFixture())
  var future = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
  future["version"] = 999
  var alias = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
  let windows = try #require(alias["windows"] as? [[String: Any]])
  alias["windows"] = windows + windows
  for bad in [
    Data("{malformed".utf8), try JSONSerialization.data(withJSONObject: future),
    try JSONSerialization.data(withJSONObject: alias),
  ] {
    try bad.write(to: file.url)
    #expect(throws: (any Error).self) { _ = try file.load() }
    #expect(try Data(contentsOf: file.url) == bad)
  }
}

@Test func newPinsAndNewProfileSpacesPropagateWithoutCopyingOrdinaryTabs() throws {
  var workspace = try BrowserWorkspace(session: workspaceFixture())
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  var first = workspace.windows[0].session
  let addedSpace = first.addSpace(name: "New account")!
  let newProfile = first.selectedSpace.profileID
  let tab = first.open(URL(string: "https://example.com/new-pin")!)!
  first.togglePin(tab)
  let ordinary = first.open(URL(string: "https://example.com/new-ordinary")!)!
  try workspace.updateWindow(firstID, session: first)
  let second = workspace.window(secondID)!.session
  let shared = try #require(second.spaces.first { $0.id == addedSpace })
  #expect(shared.profileID == newProfile)
  #expect(shared.tabs.count == 1 && shared.tabs[0].isPinned)
  #expect(shared.tabs[0].id != tab && shared.tabs[0].id != ordinary)
  #expect(shared.tabs[0].url == first.spaces.last!.tabs.first!.url)
  #expect(second.selectedSpaceID != addedSpace)
  #expect(workspace.window(firstID)!.session.selectedSpace.selectedTabID == ordinary)
  try workspace.validate()
}
