import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct SpaceProfileStoreTests {
  @Test func reassignmentBroadcastsAndPersistsAllWindows() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    var initial = BrowserSession.fresh()
    let spaceID = initial.selectedSpaceID
    let opened = initial.open(URL(string: "https://example.test/page")!)
    let tabID = try #require(opened)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: initial)
    let first = manager.workspace.windows[0].id
    let second = try manager.newWindow(from: first)
    let store = try #require(manager.stores[first])
    let target = initial.profiles[1].id
    #expect(store.setSpaceProfile(spaceID, to: target))
    #expect(store.session.profileID(forTabID: tabID) == target)
    #expect(manager.stores[second]?.session.spaces.first { $0.id == spaceID }?.profileID == target)
    #expect(try file.load() == manager.workspace)
    let created = try manager.createProfile(BrowserProfile(name: "New"), assigningSpace: spaceID)
    #expect(store.session.selectedSpace.profileID == created)
    #expect(store.session.profiles.first { $0.id == created }?.name == "New")
    #expect(manager.stores[second]?.session.spaces.first { $0.id == spaceID }?.profileID == created)
    #expect(try file.load() == manager.workspace)
  }
}
