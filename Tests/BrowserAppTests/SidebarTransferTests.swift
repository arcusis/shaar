import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarTransferTests {
  private func session() -> BrowserSession {
    var session = BrowserSession.fresh()
    let source = session.selectedSpace
    session.open(URL(string: "https://example.com/first")!)
    session.open(URL(string: "https://example.com/second")!)
    session.addSpace(name: "Shared", sharingProfile: source.profileID)
    session.selectSpace(source.id)
    return session
  }

  @Test func foreignBrowserInstancesStaleSourcesAndMissingTargetsCannotApplyDrops() throws {
    let store = BrowserStore(session: session())
    let source = store.session.spaces[0]
    let target = store.session.spaces[2]
    let tab = try #require(source.selectedTabID)
    let foreign = SidebarTransfer.tab(sessionID: UUID(), sourceSpaceID: source.id, tabID: tab)
    let local = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: source.id, tabID: tab)
    let before = store.session
    #expect(!store.acceptSidebarDrop(foreign, into: target.id))
    #expect(!store.acceptSidebarDrop(local, into: UUID()))
    #expect(store.session == before)
    #expect(store.acceptSidebarDrop(local, into: target.id))
    let moved = store.session
    #expect(!store.acceptSidebarDrop(local, into: source.id))
    #expect(store.session == moved)
  }

  @Test func crossProfileDropsExplainTheBoundaryAndModalDialogsBlockMoves() throws {
    let store = BrowserStore(session: session())
    let source = store.session.spaces[0]
    let other = store.session.spaces[1]
    let shared = store.session.spaces[2]
    let tab = try #require(source.selectedTabID)
    let payload = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: source.id, tabID: tab)
    let before = store.session
    #expect(!store.acceptSidebarDrop(payload, into: other.id))
    #expect(store.session == before)
    #expect(store.sidebarNotice == "Tabs can move only between spaces sharing a profile.")
    store.spaceEditor = .create
    #expect(!store.acceptSidebarDrop(payload, into: shared.id))
    #expect(!store.moveSpace(shared.id, before: source.id))
    #expect(store.session == before)
    store.spaceEditor = nil
    #expect(store.acceptSidebarDrop(payload, into: shared.id))
    #expect(store.sidebarNotice == nil)
  }

  @Test func dropsPersistOrderAndOwnershipWithoutPersistingTheirRuntimeAuthority() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = SessionFile(url: folder.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file, session: session())
    let source = store.session.spaces[0]
    let target = store.session.spaces[2]
    let tab = try #require(source.selectedTabID)
    let payload = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: source.id, tabID: tab)
    let decoded = try JSONDecoder().decode(
      SidebarTransfer.self, from: JSONEncoder().encode(payload))
    #expect(store.acceptSidebarDrop(decoded, into: target.id, pinned: true))
    let spacePayload = SidebarTransfer.space(sessionID: store.dragSessionID, spaceID: target.id)
    #expect(store.acceptSidebarDrop(spacePayload, into: source.id, beforeSpace: source.id))
    let restored = BrowserStore(sessionFile: file)
    #expect(restored.session == store.session)
    #expect(restored.dragSessionID != store.dragSessionID)
    #expect(!restored.acceptSidebarDrop(decoded, into: source.id))
    let json = try String(contentsOf: file.url, encoding: .utf8)
    #expect(!json.contains(store.dragSessionID.uuidString))
    #expect(restored.session.selectedSpace.selectedTab?.id == tab)
    #expect(restored.session.selectedSpace.selectedTab?.isPinned == true)
  }
}
