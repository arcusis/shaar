// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct BrowserSettingsProfileTests {
  @Test func creatingProfileSelectsSettingsOnlyAndPreservesEveryBrowserSelection() throws {
    let session = BrowserSession.fresh()
    let workspace = try BrowserWorkspaceStore(initialSession: session)
    let firstWindowID = try #require(workspace.workspace.windows.first?.id)
    let secondWindowID = try workspace.newWindow(from: firstWindowID)
    let secondStore = try #require(workspace.stores[secondWindowID])
    let workSpaceID = try #require(
      secondStore.session.spaces.first { $0.profileID == session.profiles[1].id }?.id)
    secondStore.perform(.space(workSpaceID))

    let beforeWindowIDs = workspace.workspace.windows.map(\.id)
    let beforeSelectedSpaces = workspace.workspace.windows.map { $0.session.selectedSpaceID }
    let beforeSelectedTabs = workspace.workspace.windows.map {
      $0.session.selectedSpace.selectedTabID
    }
    let beforeAssignments = workspace.workspace.catalog.spaces.map { ($0.id, $0.profileID) }
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    settings.show(for: session.profiles[0].id)

    let addedID = try #require(settings.createProfile(name: "Unused account"))

    #expect(settings.selectedProfileID == addedID)
    #expect(settings.profiles.first { $0.id == addedID }?.spaceCount == 0)
    #expect(workspace.workspace.windows.map(\.id) == beforeWindowIDs)
    #expect(workspace.workspace.windows.map { $0.session.selectedSpaceID } == beforeSelectedSpaces)
    #expect(
      workspace.workspace.windows.map { $0.session.selectedSpace.selectedTabID }
        == beforeSelectedTabs)
    for (spaceID, profileID) in beforeAssignments {
      #expect(workspace.workspace.catalog.spaces.first { $0.id == spaceID }?.profileID == profileID)
    }
    #expect(workspace.stores[firstWindowID]?.session.selectedSpaceID == beforeSelectedSpaces[0])
    #expect(workspace.stores[secondWindowID]?.session.selectedSpaceID == workSpaceID)
    settings.close()
  }

  @Test func profileListAndSpaceNamesReflectSameCatalog() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    for profile in settings.profiles {
      let expected = workspace.workspace.catalog.spaces.filter { $0.profileID == profile.id }.map(
        \.name)
      #expect(profile.spaceNames == expected)
      #expect(profile.spaceCount == expected.count)
    }
  }

  @Test func capturedRenameIDTargetsOriginalProfileAndStaleIDLeavesWorkspaceUntouched() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let personalID = workspace.workspace.catalog.profiles[0].id
    let workID = workspace.workspace.catalog.profiles[1].id
    let browserSelections = workspace.workspace.windows.map { $0.session.selectedSpaceID }
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    settings.show(for: personalID)
    let capturedProfileID = try #require(settings.selectedProfileID)

    #expect(settings.selectProfile(workID))
    #expect(settings.renameProfile(capturedProfileID, name: "Personal renamed"))
    #expect(settings.selectedProfileID == workID)
    #expect(settings.profiles.first { $0.id == personalID }?.name == "Personal renamed")
    #expect(settings.profiles.first { $0.id == workID }?.name == "Work")
    #expect(workspace.workspace.windows.map { $0.session.selectedSpaceID } == browserSelections)

    let beforeStaleRename = workspace.workspace
    #expect(!settings.renameProfile(UUID(), name: "Must not apply"))
    #expect(workspace.workspace == beforeStaleRename)
    settings.close()
  }

  @Test func profileSearchPreferenceAndIdentitySurviveRenameAndReload() throws {
    let root = try makeTemporaryDirectory("settings-profile-reload")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceFile = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "unused-session.json"))
    let preferencesURL = root.appending(path: "preferences.json")
    let workspace = try BrowserWorkspaceStore(file: workspaceFile, initialSession: .fresh())
    let profileID = workspace.workspace.catalog.profiles[0].id
    let preferences = BrowserPreferencesStore(fileURL: preferencesURL)
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: preferences, presentation: .hiddenProbe)
    settings.show(for: profileID)

    #expect(settings.selectSearchEngine(BrowserSearchEngine.duckDuckGo.rawValue, for: profileID))
    #expect(settings.renameProfile(profileID, name: "Personal renamed"))
    #expect(preferences.searchEngine(for: profileID) == .duckDuckGo)
    settings.close()

    let reloadedWorkspace = try BrowserWorkspaceStore(
      file: workspaceFile, initialSession: .fresh())
    let reloadedPreferences = BrowserPreferencesStore(fileURL: preferencesURL)
    let reloadedProfile = try #require(
      reloadedWorkspace.workspace.catalog.profiles.first { $0.id == profileID })
    #expect(reloadedProfile.name == "Personal renamed")
    #expect(reloadedPreferences.searchEngine(for: profileID) == .duckDuckGo)
    #expect(
      reloadedWorkspace.workspace.windows[0].session.profiles.first { $0.id == profileID }?.id
        == profileID)
  }

  @Test func newProfileCanOwnPersistedSpaceWithoutReassigningExistingSpaces() throws {
    let root = try makeTemporaryDirectory("settings-profile-space")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceFile = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "unused-session.json"))
    let workspace = try BrowserWorkspaceStore(file: workspaceFile, initialSession: .fresh())
    let windowID = try #require(workspace.workspace.windows.first?.id)
    let browserStore = try #require(workspace.stores[windowID])
    let originalAssignments = workspace.workspace.catalog.spaces.map { ($0.id, $0.profileID) }
    let originalSelectedSpaceID = browserStore.session.selectedSpaceID
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    settings.show(for: browserStore.session.selectedSpace.profileID)
    let newProfileID = try #require(settings.createProfile(name: "Project account"))
    #expect(settings.profiles.first { $0.id == newProfileID }?.spaceCount == 0)
    #expect(browserStore.session.selectedSpaceID == originalSelectedSpaceID)

    #expect(browserStore.createSpace(name: "Project", sharingProfile: newProfileID, tint: .forest))

    let createdSpace = try #require(
      browserStore.session.spaces.first { $0.name == "Project" })
    #expect(createdSpace.profileID == newProfileID)
    #expect(browserStore.session.selectedSpaceID == createdSpace.id)
    #expect(settings.profiles.first { $0.id == newProfileID }?.spaceCount == 1)
    #expect(settings.profiles.first { $0.id == newProfileID }?.spaceNames == ["Project"])
    for (spaceID, profileID) in originalAssignments {
      #expect(workspace.workspace.catalog.spaces.first { $0.id == spaceID }?.profileID == profileID)
    }

    let savedWorkspace = workspace.workspace
    let reloadedWorkspace = try BrowserWorkspaceStore(
      file: workspaceFile, initialSession: .fresh())
    #expect(reloadedWorkspace.workspace == savedWorkspace)
    #expect(reloadedWorkspace.stores[windowID]?.session == browserStore.session)
    #expect(reloadedWorkspace.workspace.catalog.profiles.first { $0.id == newProfileID } != nil)
    settings.close()
  }

  @Test func failedWorkspaceWriteKeepsCreatedProfileAndExposesNotice() throws {
    let root = try makeTemporaryDirectory("settings-profile-write-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceURL = root.appending(path: "workspace.json")
    let workspaceFile = WorkspaceFile(
      url: workspaceURL, legacySessionURL: root.appending(path: "unused-session.json"))
    let workspace = try BrowserWorkspaceStore(file: workspaceFile, initialSession: .fresh())
    let profileBefore = workspace.workspace.catalog.profiles[0]
    let windowID = try #require(workspace.workspace.windows.first?.id)
    #expect(FileManager.default.fileExists(atPath: workspaceURL.path))
    #expect(workspace.storageNotice == nil)

    try FileManager.default.removeItem(at: workspaceURL)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    settings.show(for: profileBefore.id)

    let addedID = try #require(settings.createProfile(name: "Unsaved but active"))

    #expect(workspace.workspace.catalog.profiles.contains { $0.id == addedID })
    #expect(
      workspace.workspace.catalog.profiles.first { $0.id == profileBefore.id } == profileBefore)
    #expect(
      workspace.workspace.windows.first?.session.profiles.contains { $0.id == addedID } == true)
    try workspace.workspace.validate()
    #expect(workspace.storageNotice?.contains("could not be saved") == true)
    #expect(workspace.stores[windowID]?.storageNotice == workspace.storageNotice)
    #expect(settings.selectedProfileID == addedID)
    settings.close()
  }
}

@MainActor
private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "\(prefix)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
