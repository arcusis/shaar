import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FolderStoreTests {
  @Test func folderEditorsCannotReplaceConsentOrEditAnotherSpaceAfterSwitching() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let folder = try #require(store.createFolder(name: "Projects", in: space))
    let route = FolderEditorRoute.edit(spaceID: space, folderID: folder)
    store.showFolderEditor(route)
    #expect(store.sheet?.id == BrowserSheet.folder(route).id)
    store.cycleSpace(by: 1)
    #expect(store.sheet == nil)
    #expect(!store.renameFolder(folder, in: space, name: "Stale"))
    #expect(store.session.spaces.first { $0.id == space }?.folders[0].name == "Projects")
    store.perform(.open(URL(string: "https://example.com")!))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(
      WebsiteMediaRequest(
        id: "p1", profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://example.com")!,
        kinds: [.camera]))
    #expect(store.requestWebsiteMedia(request))
    store.showFolderEditor(.create(spaceID: store.session.selectedSpaceID, parentID: nil))
    #expect(store.sheet?.id == "media-p1")
    #expect(store.createFolder(name: "Unseen", in: store.session.selectedSpaceID) == nil)
  }

  @Test func folderDropsRejectForeignAuthorityAndDifferentProfiles() throws {
    let store = BrowserStore()
    let source = store.session.selectedSpace
    let other = store.session.spaces[1]
    let folder = try #require(store.createFolder(name: "Projects", in: source.id))
    let foreign = SidebarTransfer.folder(
      sessionID: UUID(), sourceSpaceID: source.id, folderID: folder)
    #expect(!store.acceptSidebarDrop(foreign, into: source.id))
    let valid = SidebarTransfer.folder(
      sessionID: store.dragSessionID, sourceSpaceID: source.id, folderID: folder)
    let before = store.session
    #expect(!store.acceptSidebarDrop(valid, into: other.id))
    #expect(store.session == before)
    #expect(store.sidebarNotice == "Folders can move only between spaces sharing a profile.")
    #expect(store.createSpace(name: "Shared", sharingProfile: source.profileID, tint: .forest))
    let destination = store.session.selectedSpaceID
    #expect(store.acceptSidebarDrop(valid, into: destination))
    #expect(store.session.selectedSpace.folders.first?.id == folder)
    #expect(!store.acceptSidebarDrop(valid, into: source.id))
  }

  @Test func invalidV2FolderFileIsPreservedWhenTemporarySessionChanges() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = SessionFile(url: root.appending(path: "session.json"))
    var wire = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSession.fresh()))
        as? [String: Any])
    var spaces = try #require(wire["spaces"] as? [[String: Any]])
    let id = UUID().uuidString
    spaces[0]["folders"] = [["id": id, "name": "Cycle", "parentID": id, "isCollapsed": false]]
    wire["spaces"] = spaces
    let original = try JSONSerialization.data(withJSONObject: wire)
    try original.write(to: file.url)
    let store = BrowserStore(sessionFile: file)
    #expect(store.storageNotice != nil)
    #expect(store.createFolder(name: "Temporary", in: store.session.selectedSpaceID) != nil)
    #expect(try Data(contentsOf: file.url) == original)
  }
}
