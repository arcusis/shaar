// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Suite struct WorkspaceProfileTests {
  @Test func invalidProfileEditsAreTransactional() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    let original = workspace
    let profileID = workspace.catalog.profiles[0].id
    for name in ["", " \t\n"] {
      #expect(throws: WorkspaceError.self) { try workspace.createProfile(name: name) }
      #expect(workspace == original)
      #expect(throws: WorkspaceError.self) { try workspace.renameProfile(profileID, name: name) }
      #expect(workspace == original)
    }
    #expect(throws: WorkspaceError.self) { try workspace.renameProfile(UUID(), name: "Other") }
    #expect(workspace == original)
  }

  @Test func unusedDuplicateProfilesAndLargeCatalogSurviveWindowlessReload() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    let originalSpaces = workspace.catalog.spaces
    try workspace.removeWindow(workspace.windows[0].id)
    let first = try workspace.createProfile(name: "  Team  ")
    let second = try workspace.createProfile(name: "Team")
    #expect(first != second)
    #expect(workspace.catalog.profiles.filter { $0.name == "Team" }.count == 2)
    for index in 0..<125 { _ = try workspace.createProfile(name: "Account \(index)") }
    try workspace.renameProfile(first, name: "  Renamed  ")
    #expect(workspace.catalog.profiles.count == 129)
    #expect(Set(workspace.catalog.profiles.map(\.id)).count == 129)
    #expect(workspace.catalog.profiles.first { $0.id == first }?.name == "Renamed")
    #expect(workspace.catalog.profiles.first { $0.id == second }?.name == "Team")
    #expect(workspace.catalog.spaces == originalSpaces)
    #expect(workspace.windows.isEmpty && workspace.focusedWindowID == nil)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "unused-session.json"))
    try file.save(workspace)
    #expect(try file.load() == workspace)
  }

  @Test func profileEditsRetainWindowNavigationRecoveryPinsFoldersAndGeometry() throws {
    var session = BrowserSession.fresh()
    let spaceID = session.selectedSpaceID
    let openedPin = session.open(URL(string: "https://example.test/pin")!)
    let pin = try #require(openedPin)
    session.togglePin(pin)
    let createdFolder = session.addFolder(name: "Tools", in: spaceID)
    let folder = try #require(createdFolder)
    let movedPin = session.moveTab(pin, from: spaceID, to: spaceID, folderID: folder)
    #expect(movedPin)
    let toggledFolder = session.toggleFolder(folder, in: spaceID)
    #expect(toggledFolder)
    let openedOrdinary = session.open(URL(string: "https://example.test/live")!)
    let ordinary = try #require(openedOrdinary)
    let openedClosed = session.open(URL(string: "https://example.test/closed")!)
    let closed = try #require(openedClosed)
    session.closeTab(closed)
    session.selectTab(ordinary, in: spaceID)
    var workspace = try BrowserWorkspace(session: session)
    let firstID = workspace.windows[0].id
    let secondID = try workspace.addWindow(from: firstID)
    var second = try #require(workspace.window(secondID)?.session)
    let openedSecond = second.open(URL(string: "https://example.test/second-window")!)
    _ = try #require(openedSecond)
    try workspace.updateWindow(secondID, session: second)
    try workspace.setGeometry(
      WorkspaceWindowGeometry(x: 40, y: 50, width: 1100, height: 720), for: firstID)
    try workspace.setGeometry(
      WorkspaceWindowGeometry(x: 80, y: 90, width: 1000, height: 640), for: secondID)
    try workspace.focusWindow(firstID)
    let before = workspace
    let added = try workspace.createProfile(name: "Extra")
    try workspace.renameProfile(session.profiles[0].id, name: "Renamed")
    var expectedProfiles = before.catalog.profiles
    expectedProfiles[0].name = "Renamed"
    expectedProfiles.append(BrowserProfile(id: added, name: "Extra"))
    #expect(workspace.catalog.profiles == expectedProfiles)
    #expect(workspace.catalog.spaces == before.catalog.spaces)
    #expect(workspace.focusedWindowID == before.focusedWindowID)
    #expect(workspace.windows.map(\.id) == before.windows.map(\.id))
    for (after, prior) in zip(workspace.windows, before.windows) {
      #expect(after.geometry == prior.geometry && after.pins == prior.pins)
      #expect(after.session.spaces == prior.session.spaces)
      #expect(after.session.closedTabs == prior.session.closedTabs)
      #expect(after.session.selectedSpaceID == prior.session.selectedSpaceID)
      #expect(after.session.profiles == expectedProfiles)
    }
    try workspace.validate()
  }

  @Test func profileCatalogEditsPreserveWindowSelectionsAndRejectStaleIDs() throws {
    let personal = BrowserProfile(name: "Personal")
    let work = BrowserProfile(name: "Work")
    let personalTab = BrowserTab(url: URL(string: "https://personal.example.test")!)
    let workTab = BrowserTab(url: URL(string: "https://work.example.test")!)
    let personalSpace = BrowserSpace(
      profileID: personal.id, name: "Personal", symbol: "house", tint: .lavender,
      tabs: [personalTab])
    let workSpace = BrowserSpace(
      profileID: work.id, name: "Work", symbol: "briefcase", tint: .ocean, tabs: [workTab])
    let session = try BrowserSession(
      profiles: [personal, work], spaces: [personalSpace, workSpace],
      selectedSpaceID: personalSpace.id)
    var workspace = try BrowserWorkspace(session: session)
    let firstWindowID = workspace.windows[0].id
    let secondWindowID = try workspace.addWindow(from: firstWindowID)
    var secondSession = try #require(workspace.window(secondWindowID)?.session)
    secondSession.selectSpace(workSpace.id)
    try workspace.updateWindow(secondWindowID, session: secondSession)

    let windowIDs = workspace.windows.map(\.id)
    let selectedSpaces = workspace.windows.map { $0.session.selectedSpaceID }
    let selectedTabs = workspace.windows.map { $0.session.selectedSpace.selectedTabID }
    let assignments = workspace.catalog.spaces.map { ($0.id, $0.profileID) }
    let addedID = try workspace.createProfile(name: "  Unused  ")

    #expect(workspace.catalog.profiles.last?.id == addedID)
    #expect(workspace.catalog.profiles.last?.name == "Unused")
    #expect(workspace.catalog.spaces.count == assignments.count)
    #expect(workspace.windows.map(\.id) == windowIDs)
    #expect(workspace.windows.map { $0.session.selectedSpaceID } == selectedSpaces)
    #expect(workspace.windows.map { $0.session.selectedSpace.selectedTabID } == selectedTabs)
    for (spaceID, profileID) in assignments {
      #expect(workspace.catalog.spaces.first { $0.id == spaceID }?.profileID == profileID)
    }

    try workspace.renameProfile(personal.id, name: "Personal renamed")
    #expect(workspace.catalog.profiles.first { $0.id == personal.id }?.name == "Personal renamed")
    #expect(workspace.catalog.profiles.first { $0.name == "Personal renamed" }?.id == personal.id)
    #expect(workspace.windows.map(\.id) == windowIDs)
    #expect(workspace.windows.map { $0.session.selectedSpaceID } == selectedSpaces)
    #expect(workspace.windows.map { $0.session.selectedSpace.selectedTabID } == selectedTabs)

    let beforeStaleRename = workspace
    #expect(throws: WorkspaceError.self) {
      try workspace.renameProfile(UUID(), name: "Must not apply")
    }
    #expect(workspace == beforeStaleRename)
    #expect(throws: WorkspaceError.self) { try workspace.createProfile(name: "  ") }
    #expect(workspace == beforeStaleRename)
  }
}

@Suite struct WorkspaceProfileColorTests {
  @Test func createdAndUpdatedProfileColorsPersistThroughTheCatalog() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    let chosenID = UUID()
    let custom = SpaceRGBColor(red: 18, green: 52, blue: 86)
    let created = try workspace.createProfile(name: "Work", tint: .ocean, id: chosenID)
    #expect(created == chosenID)
    try workspace.setProfileColor(workspace.catalog.profiles[0].id, tint: nil, customRGB: custom)

    let work = try #require(workspace.catalog.profiles.first { $0.id == chosenID })
    #expect(work.tint == .ocean && work.customRGB == nil)
    #expect(workspace.catalog.profiles[0].customRGB == custom)
    #expect(workspace.windows[0].session.profiles == workspace.catalog.profiles)

    try workspace.setProfileColor(chosenID, tint: nil, customRGB: nil)
    #expect(workspace.catalog.profiles.first { $0.id == chosenID }?.tint == nil)

    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    try file.save(workspace)
    #expect(try file.load() == workspace)
  }

  @Test func profileCreationRejectsAnIdentityAlreadyInUse() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    let original = workspace
    let existing = workspace.catalog.profiles[0].id
    #expect(throws: WorkspaceError.self) {
      try workspace.createProfile(name: "Duplicate", id: existing)
    }
    #expect(throws: WorkspaceError.self) {
      try workspace.setProfileColor(UUID(), tint: .rose, customRGB: nil)
    }
    #expect(workspace == original)
  }

  @Test func catalogSavedBeforeProfileColorsDecodesWithoutColor() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    try workspace.setProfileColor(workspace.catalog.profiles[0].id, tint: .forest, customRGB: nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))
    var root = try #require(object as? [String: Any])
    var catalog = try #require(root["catalog"] as? [String: Any])
    catalog["profiles"] = try Self.withoutColors(catalog["profiles"])
    root["catalog"] = catalog
    let windows = try #require(root["windows"] as? [[String: Any]])
    root["windows"] = try windows.map { window in
      var window = window
      var session = try #require(window["session"] as? [String: Any])
      session["profiles"] = try Self.withoutColors(session["profiles"])
      window["session"] = session
      return window
    }

    let older = try JSONSerialization.data(withJSONObject: root)
    let decoded = try JSONDecoder().decode(BrowserWorkspace.self, from: older)
    #expect(decoded.catalog.profiles.allSatisfy { $0.tint == nil && $0.customRGB == nil })
    #expect(decoded.catalog.profiles.map(\.id) == workspace.catalog.profiles.map(\.id))
  }

  private static func withoutColors(_ profiles: Any?) throws -> [[String: Any]] {
    let profiles = try #require(profiles as? [[String: Any]])
    return profiles.map { $0.filter { !["tint", "customRGB"].contains($0.key) } }
  }
}
