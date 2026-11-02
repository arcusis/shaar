// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@testable import ArcusisBrowser

struct SavedTabCapacityIdentityCheckpoint: Codable, Equatable {
  struct Tab: Codable, Equatable {
    let id: UUID
    let url: String
    let title: String
    let isPinned: Bool
    let folderID: UUID?
  }

  struct Folder: Codable, Equatable {
    let id: UUID
    let name: String
    let parentID: UUID?
    let isCollapsed: Bool
  }

  struct Space: Codable, Equatable {
    let id: UUID
    let profileID: UUID
    let name: String
    let symbol: String
    let tint: SpaceTint
    let tabs: [Tab]
    let selectedTabID: UUID?
    let folders: [Folder]
  }

  let schema: Int
  let runID: UUID
  let windowID: UUID
  let selectedSpaceID: UUID
  let profiles: [BrowserProfile]
  let spaces: [Space]

  init(workspace: BrowserWorkspace, windowID: UUID, runID: UUID) throws {
    guard let window = workspace.window(windowID) else {
      throw SavedTabCapacityFailure("Managed capacity window is missing.")
    }
    schema = 1
    self.runID = runID
    self.windowID = windowID
    selectedSpaceID = window.session.selectedSpaceID
    profiles = window.session.profiles
    spaces = window.session.spaces.map { space in
      Space(
        id: space.id, profileID: space.profileID, name: space.name,
        symbol: space.symbol, tint: space.tint,
        tabs: space.tabs.map {
          Tab(
            id: $0.id, url: $0.url.absoluteString, title: $0.title,
            isPinned: $0.isPinned, folderID: $0.folderID)
        },
        selectedTabID: space.selectedTabID,
        folders: space.folders.map {
          Folder(id: $0.id, name: $0.name, parentID: $0.parentID, isCollapsed: $0.isCollapsed)
        })
    }
  }

  func matches(_ workspace: BrowserWorkspace, ignoringTabTitles: Bool = false) -> Bool {
    guard schema == 1, workspace.windows.count == 1,
      let window = workspace.window(windowID), workspace.focusedWindowID == windowID,
      window.session.selectedSpaceID == selectedSpaceID,
      window.session.profiles == profiles,
      window.session.spaces.count == spaces.count
    else { return false }

    return zip(window.session.spaces, spaces).allSatisfy { actual, saved in
      actual.id == saved.id && actual.profileID == saved.profileID
        && actual.name == saved.name && actual.symbol == saved.symbol && actual.tint == saved.tint
        && actual.selectedTabID == saved.selectedTabID
        && actual.tabs.count == saved.tabs.count
        && zip(actual.tabs, saved.tabs).allSatisfy { tab, expected in
          tab.id == expected.id && tab.url.absoluteString == expected.url
            && (ignoringTabTitles || tab.title == expected.title)
            && tab.isPinned == expected.isPinned && tab.folderID == expected.folderID
        }
        && actual.folders.map {
          Folder(id: $0.id, name: $0.name, parentID: $0.parentID, isCollapsed: $0.isCollapsed)
        } == saved.folders
    }
  }
}

@MainActor
struct SavedTabCapacityFixture {
  static let spaceCount = 12
  static let tabsPerSpace = 120
  static let profileCount = 4
  static let expectedTabCount = spaceCount * tabsPerSpace
  static let mode = "saved-tab-capacity-only"
  static let scope =
    "Owned managed workspace with authored loopback fixture; 1440 saved tabs, four profiles, eight visited Spaces, at most eight live tabs; no user profile or external host. Does not measure hundreds of renderers or process memory."

  let workspaceStore: BrowserWorkspaceStore
  let store: BrowserStore
  let initialCheckpoint: SavedTabCapacityIdentityCheckpoint
  let runID: UUID
  let initialCheckpointURL: URL
  let restartCheckpointURL: URL
  let workspaceURL: URL
  let phase: String

  static func open(root: URL, fixture: URL, phase: String) throws -> Self {
    guard ["initial", "restart"].contains(phase) else {
      throw SavedTabCapacityFailure("Invalid saved-tab capacity phase.")
    }
    let workspaceURL = root.appending(path: "saved-tab-capacity-workspace.json")
    let initialCheckpointURL = root.appending(path: "saved-tab-capacity-identities.json")
    let restartCheckpointURL = root.appending(path: "saved-tab-capacity-restart-identities.json")
    let workspaceFile = WorkspaceFile(
      url: workspaceURL, legacySessionURL: root.appending(path: "unused-legacy-session.json"))
    let authoredSession = try makeSession(fixture: fixture)
    let workspaceStore: BrowserWorkspaceStore

    if phase == "initial" {
      guard !FileManager.default.fileExists(atPath: workspaceURL.path),
        !FileManager.default.fileExists(atPath: initialCheckpointURL.path),
        !FileManager.default.fileExists(atPath: restartCheckpointURL.path)
      else { throw SavedTabCapacityFailure("Initial capacity artifacts already exist.") }
      workspaceStore = try BrowserWorkspaceStore(
        file: workspaceFile, initialSession: authoredSession)
    } else {
      guard FileManager.default.fileExists(atPath: workspaceURL.path),
        FileManager.default.fileExists(atPath: initialCheckpointURL.path),
        FileManager.default.fileExists(atPath: restartCheckpointURL.path)
      else { throw SavedTabCapacityFailure("Restart capacity artifacts are missing.") }
      workspaceStore = try BrowserWorkspaceStore(
        file: workspaceFile, initialSession: authoredSession)
      guard workspaceStore.storageNotice == nil else {
        throw SavedTabCapacityFailure("Managed workspace failed to restore.")
      }
    }

    guard workspaceStore.workspace.windows.count == 1,
      let window = workspaceStore.workspace.windows.first,
      let store = workspaceStore.stores[window.id]
    else { throw SavedTabCapacityFailure("Capacity workspace did not restore one managed window.") }
    guard workspaceStore.storageNotice == nil else {
      throw SavedTabCapacityFailure("Managed capacity workspace reported a storage error.")
    }

    let initialCheckpoint: SavedTabCapacityIdentityCheckpoint
    let runID: UUID
    if phase == "initial" {
      guard workspaceStore.workspace.windows.first?.session == authoredSession else {
        throw SavedTabCapacityFailure("Initial workspace snapshot differs from authored session.")
      }
      runID = UUID()
      initialCheckpoint = try SavedTabCapacityIdentityCheckpoint(
        workspace: workspaceStore.workspace, windowID: window.id, runID: runID)
      guard initialCheckpoint.matches(workspaceStore.workspace) else {
        throw SavedTabCapacityFailure(
          "Initial workspace differs from authored metadata checkpoint.")
      }
      try write(initialCheckpoint, to: initialCheckpointURL)
    } else {
      initialCheckpoint = try read(initialCheckpointURL)
      let restartCheckpoint = try read(restartCheckpointURL)
      guard initialCheckpoint.runID == restartCheckpoint.runID,
        initialCheckpoint.spaces.count == spaceCount,
        initialCheckpoint.profiles.count == profileCount,
        initialCheckpoint.spaces.allSatisfy({ $0.tabs.count == tabsPerSpace }),
        initialCheckpoint.matches(workspaceStore.workspace, ignoringTabTitles: true),
        restartCheckpoint.matches(workspaceStore.workspace)
      else {
        throw SavedTabCapacityFailure(
          "Restart workspace IDs or saved metadata differ from checkpoint.")
      }
      runID = initialCheckpoint.runID
    }

    return Self(
      workspaceStore: workspaceStore, store: store, initialCheckpoint: initialCheckpoint,
      runID: runID, initialCheckpointURL: initialCheckpointURL,
      restartCheckpointURL: restartCheckpointURL, workspaceURL: workspaceURL, phase: phase)
  }

  func recordExpectedRestartMetadata() throws {
    guard phase == "initial",
      initialCheckpoint.matches(workspaceStore.workspace, ignoringTabTitles: true)
    else {
      throw SavedTabCapacityFailure("Initial capacity metadata changed outside dynamic titles.")
    }
    // Native title changes use deferred writes. A restart checkpoint must describe durable bytes.
    try workspaceStore.flushSaves()
    let checkpoint = try SavedTabCapacityIdentityCheckpoint(
      workspace: workspaceStore.workspace, windowID: initialCheckpoint.windowID, runID: runID)
    try Self.write(checkpoint, to: restartCheckpointURL)
  }

  private static func makeSession(fixture: URL) throws -> BrowserSession {
    let profiles = (0..<profileCount).map { index in
      BrowserProfile(id: identity(kind: 1, index: index), name: "Capacity Account \(index)")
    }
    let spaces = (0..<spaceCount).map { spaceIndex -> BrowserSpace in
      let rootFolderID = identity(kind: 3, index: spaceIndex * 2)
      let nestedFolderID = identity(kind: 3, index: spaceIndex * 2 + 1)
      let tabs = (0..<tabsPerSpace).map { tabIndex -> BrowserTab in
        let pinned = tabIndex.isMultiple(of: 8)
        let folderID: UUID? =
          switch tabIndex {
          case 0: rootFolderID
          case 8, 24: nestedFolderID
          default: nil
          }
        return BrowserTab(
          id: identity(kind: 4, index: spaceIndex * tabsPerSpace + tabIndex),
          url: fixture, title: "Saved Space \(spaceIndex) Tab \(tabIndex)",
          isPinned: pinned, folderID: folderID)
      }
      return BrowserSpace(
        id: identity(kind: 2, index: spaceIndex), profileID: profiles[spaceIndex % profileCount].id,
        name: "Saved Space \(spaceIndex)", symbol: "square.stack",
        tint: SpaceTint.allCases[spaceIndex % SpaceTint.allCases.count], tabs: tabs,
        selectedTabID: tabs[spaceIndex % tabs.count].id,
        folders: [
          BrowserFolder(id: rootFolderID, name: "Pinned \(spaceIndex)"),
          BrowserFolder(
            id: nestedFolderID, name: "Nested \(spaceIndex)", parentID: rootFolderID,
            isCollapsed: spaceIndex.isMultiple(of: 2)),
        ])
    }
    return try BrowserSession(
      profiles: profiles, spaces: spaces, selectedSpaceID: spaces[0].id)
  }

  private static func identity(kind: Int, index: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", kind, index))!
  }

  private static func write(
    _ checkpoint: SavedTabCapacityIdentityCheckpoint, to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(checkpoint).write(to: url, options: .atomic)
  }

  private static func read(_ url: URL) throws -> SavedTabCapacityIdentityCheckpoint {
    try JSONDecoder().decode(SavedTabCapacityIdentityCheckpoint.self, from: Data(contentsOf: url))
  }
}

struct SavedTabCapacityFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
