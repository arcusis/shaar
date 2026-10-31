import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite
struct SavedTabCapacityTests {
  @MainActor
  @Test func managedWorkspaceRestoresFourProfilesAnd1440TabsWithExactMetadata() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "saved-tab-capacity-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fixtureURL = URL(string: "http://127.0.0.1:43123/account")!
    let initial = try SavedTabCapacityFixture.open(
      root: root, fixture: fixtureURL, phase: "initial")
    let session = initial.store.session
    #expect(session.profiles.count == 4)
    #expect(session.spaces.count == 12)
    #expect(session.spaces.flatMap(\.tabs).count == 1440)
    #expect(session.spaces.allSatisfy { $0.tabs.count == 120 })
    #expect(session.spaces.map(\.profileID) == (0..<12).map { session.profiles[$0 % 4].id })
    #expect(session.spaces.allSatisfy { $0.tabs.filter(\.isPinned).count == 15 })
    #expect(session.spaces.allSatisfy { $0.folders.count == 2 })
    #expect(session.selectedSpaceID == session.spaces[0].id)
    #expect(initial.initialCheckpoint.matches(initial.workspaceStore.workspace))
    #expect(FileManager.default.fileExists(atPath: initial.workspaceURL.path))
    #expect(FileManager.default.fileExists(atPath: initial.initialCheckpointURL.path))

    let selected = session.spaces[0].selectedTab!
    initial.store.nativeTabChanged(selected.id, url: selected.url, title: "Dynamic engine title")
    #expect(initial.workspaceStore.storageNotice == nil)
    #expect(
      initial.initialCheckpoint.matches(
        initial.workspaceStore.workspace, ignoringTabTitles: true))
    try initial.recordExpectedRestartMetadata()
    let restartMetadata = try JSONDecoder().decode(
      SavedTabCapacityIdentityCheckpoint.self,
      from: Data(contentsOf: initial.restartCheckpointURL))
    #expect(restartMetadata.runID == initial.runID)
    #expect(restartMetadata.spaces[0].tabs[0].title == "Dynamic engine title")

    let restarted = try SavedTabCapacityFixture.open(
      root: root, fixture: fixtureURL, phase: "restart")
    #expect(restarted.runID == initial.runID)
    #expect(restarted.initialCheckpoint == initial.initialCheckpoint)
    #expect(restartMetadata.matches(restarted.workspaceStore.workspace))
    #expect(restarted.store.session.selectedSpaceID == session.selectedSpaceID)
    #expect(restarted.store.session.profiles == session.profiles)
    #expect(
      restarted.store.session.spaces == initial.workspaceStore.workspace.windows[0].session.spaces)
  }

  @MainActor
  @Test func restartRejectsChangedIdentityMetadataAndUnboundCheckpoint() throws {
    for mutation in [
      "runID", "profile", "space", "tabID", "url", "title", "pin", "folder",
      "selection", "collapse", "window",
    ] {
      let root = FileManager.default.temporaryDirectory
        .appending(path: "saved-tab-capacity-tests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let fixtureURL = URL(string: "http://127.0.0.1:43123/account")!
      let initial = try SavedTabCapacityFixture.open(
        root: root, fixture: fixtureURL, phase: "initial")
      try initial.recordExpectedRestartMetadata()
      var checkpoint =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: initial.restartCheckpointURL)) as! [String: Any]
      var spaces = checkpoint["spaces"] as! [[String: Any]]
      var tabs = spaces[0]["tabs"] as! [[String: Any]]
      var folders = spaces[0]["folders"] as! [[String: Any]]
      switch mutation {
      case "runID": checkpoint["runID"] = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
      case "profile": spaces[0]["profileID"] = UUID().uuidString
      case "space": spaces[0]["id"] = UUID().uuidString
      case "tabID": tabs[0]["id"] = UUID().uuidString
      case "url": tabs[0]["url"] = "http://127.0.0.1:43123/changed"
      case "title": tabs[0]["title"] = "Unexpected title"
      case "pin": tabs[0]["isPinned"] = !(tabs[0]["isPinned"] as! Bool)
      case "folder": tabs[0]["folderID"] = UUID().uuidString
      case "selection": spaces[0]["selectedTabID"] = UUID().uuidString
      case "collapse": folders[1]["isCollapsed"] = !(folders[1]["isCollapsed"] as! Bool)
      case "window": checkpoint["windowID"] = UUID().uuidString
      default: Issue.record("Unknown metadata mutation: \(mutation)")
      }
      spaces[0]["tabs"] = tabs
      spaces[0]["folders"] = folders
      checkpoint["spaces"] = spaces
      try JSONSerialization.data(withJSONObject: checkpoint)
        .write(to: initial.restartCheckpointURL, options: .atomic)
      #expect(throws: (any Error).self) {
        try SavedTabCapacityFixture.open(root: root, fixture: fixtureURL, phase: "restart")
      }
    }
  }
}
