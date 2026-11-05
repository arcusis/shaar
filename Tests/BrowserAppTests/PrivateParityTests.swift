// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivateParityTests {
  private func makeStore(source: UUID = UUID()) throws -> BrowserStore {
    BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: source, firstTabID: UUID()))
  }

  @Test func privateWindowUsesBrowserStoreWithoutWritingWorkspace() throws {
    let source = UUID()
    let tab = UUID()
    let session = try BrowserSession.privateWindow(sourceProfileID: source, firstTabID: tab)
    let store = BrowserStore(privateSession: session)
    #expect(store.isPrivate)
    #expect(store.session.selectedPage?.tab.id == tab)
    #expect(store.session.profiles.map(\.id) == [source])
    #expect(store.session.favorites.isEmpty)
    store.perform(.open(URL(string: "https://example.com/private")!))
    #expect(store.session.selectedSpace.tabs.count == 2)
  }

  @Test func splitMemberFavoriteActionRejectsNonWebPages() throws {
    let store = try makeStore()
    let blank = try #require(store.session.selectedSpace.selectedTabID)
    store.perform(.open(URL(string: "https://example.com/private")!))
    let web = try #require(store.session.selectedSpace.selectedTabID)
    store.splitTabs(blank, web)
    #expect(!store.canAddTabToFavorites(blank, in: store.session.selectedSpaceID))
    #expect(store.canAddTabToFavorites(web, in: store.session.selectedSpaceID))
  }

  @Test func privateCommandSurfaceIncludesBrowserTabCommands() {
    for command in [
      BrowserMenuCommand.newTab, .search, .closeTab, .reopenClosed, .createFolder,
      .splitView, .nextSpace, .previousSpace, .sidebar, .reload, .find,
    ] {
      #expect(PrivateBrowserHost.supportsPrivateCommand(command))
    }
    #expect(ShortcutCatalog.shortcut(for: .newTab)?.key == "t")
    #expect(ShortcutCatalog.shortcut(for: .closeTab)?.key == "w")
    #expect(ShortcutCatalog.shortcut(for: .search)?.key == "l")
    #expect(ShortcutCatalog.shortcut(for: .reopenClosed)?.key == "t")
    #expect(ShortcutCatalog.shortcut(for: .createFolder)?.key == "n")
    #expect(!PrivateBrowserHost.supportsPrivateCommand(.history))
    #expect(!PrivateBrowserHost.supportsPrivateCommand(.downloads))
  }

  @Test func privateFavoriteMenuRequiresWebPage() throws {
    let store = try makeStore()
    #expect(!PrivateBrowserHost.windowCanPerform(.addFavorite, store: store))
    store.perform(.open(URL(string: "https://example.com/private")!))
    #expect(PrivateBrowserHost.windowCanPerform(.addFavorite, store: store))
  }

  @Test func splitMenuRequiresAnAvailableTabOutsideTheCurrentSplit() throws {
    let store = try makeStore()
    let first = try #require(store.session.selectedSpace.selectedTabID)
    store.perform(.open(URL(string: "https://example.com/private")!))
    let second = try #require(store.session.selectedSpace.selectedTabID)
    #expect(PrivateBrowserHost.windowCanPerform(.splitView, store: store))

    store.splitTabs(first, second)

    #expect(!PrivateBrowserHost.windowCanPerform(.splitView, store: store))
  }

  @Test func privateTabsFoldersAndSplitsNeverEnterWorkspaceFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let before = try Data(contentsOf: file.url)
    let source = try #require(workspace.workspace.catalog.profiles.first?.id)
    let store = try makeStore(source: source)
    store.perform(.open(URL(string: "https://example.com/private")!))
    let tab = try #require(store.session.selectedPage?.tab.id)
    let folder = try #require(
      store.createFolder(
        name: "Private folder", in: store.session.selectedSpaceID))
    #expect(
      store.moveTab(
        tab, from: store.session.selectedSpaceID,
        to: store.session.selectedSpaceID, folderID: folder))
    store.perform(.open(URL(string: "https://example.org/private")!))
    store.splitSelectedTab()
    store.nativeTabClosed(tab)
    #expect(store.session.closedTabs.count == 1)
    #expect(store.reopenLastClosedTab())
    try store.flushSaves()
    try workspace.flushSaves()
    #expect(try Data(contentsOf: file.url) == before)
    #expect(workspace.workspace.windows.allSatisfy { $0.session != store.session })
    #expect(!FileManager.default.fileExists(atPath: file.legacySessionURL.path))
  }

  @Test func privateHistoryBookmarksAndDownloadsHaveNoSavedStore() throws {
    let store = try makeStore()
    store.showLibrary(.history)
    store.showLibrary(.bookmarks)
    store.showDownloads()
    #expect(!store.showLibraryDrawer(.downloads))
    #expect(store.sheet == nil)
    #expect(store.library.history.isEmpty && store.library.bookmarks.isEmpty)
    #expect(store.library.onLoad == nil && store.library.onMutation == nil)
    #expect(store.engine == nil && store.faviconCache == nil)
  }

  @Test func privateSidebarLibraryControlOpensSpaces() throws {
    let store = try makeStore()
    #expect(store.toggleLibraryDrawer())
    #expect(store.libraryDrawerSection == .spaces)
    #expect(store.toggleLibraryDrawer())
    #expect(store.libraryDrawerSection == nil)
    #expect(!store.showLibraryDrawer(.downloads))
  }

  @Test func privateFaviconCannotWriteEvenWhenCacheIsInjected() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore()
    store.faviconCache = FaviconCache(directory: root)
    store.perform(.open(URL(string: "https://example.com/private")!))
    #expect(store.addCurrentPageAsFavorite())
    let tab = try #require(store.session.selectedPage?.tab.id)
    store.rememberFavicon(NSImage(size: NSSize(width: 16, height: 16)), forTab: tab)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func everyPrivateModelTabKeepsTheSourceProfile() throws {
    let source = UUID()
    let store = try makeStore(source: source)
    for address in ["https://example.com/a", "https://example.com/b"] {
      store.perform(.open(URL(string: address)!))
    }
    for tab in store.session.spaces.flatMap(\.tabs) {
      #expect(store.session.profileID(forTabID: tab.id) == source)
    }
    #expect(store.session.profiles.map(\.id) == [source])
    #expect(!store.createSpace(name: "Wrong profile", sharingProfile: nil, tint: .ocean))
  }

  @Test func pendingHTTPCannotFollowPrivateTabSelection() throws {
    let store = try makeStore()
    let first = try #require(store.session.selectedPage?.tab.id)
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: first, store: store)
    store.navigate("http://example.com/secret")
    #expect(page.pendingHTTP?.host() == "example.com")
    store.openTab()
    page.confirmHTTP(useHTTPS: false)
    #expect(page.pendingHTTP == nil)
    #expect(store.session.selectedPage?.tab.id != first)
  }

  @Test func sharedPrivateWindowRendersBothSplitPageContainers() throws {
    let store = try makeStore()
    let first = try #require(store.session.selectedPage?.tab.id)
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: first, store: store)
    store.openTab()
    store.splitSelectedTab()
    #expect(store.selectedSplit != nil)
    let hosting = NSHostingView(rootView: BrowserWindow(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
    hosting.layoutSubtreeIfNeeded()
    func containers(in view: NSView) -> Int {
      (view is ChromiumPageContainerView ? 1 : 0)
        + view.subviews.reduce(0) { $0 + containers(in: $1) }
    }
    #expect(containers(in: hosting) == 2)
    withExtendedLifetime(page) {}
  }

  @Test func retiringSharedPrivateWindowReleasesItsStore() async throws {
    weak var releasedStore: BrowserStore?
    let hosting = try autoreleasepool { () -> NSHostingView<BrowserWindow?> in
      let store = try makeStore()
      releasedStore = store
      return NSHostingView(rootView: BrowserWindow(store: store))
    }
    hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    hosting.layoutSubtreeIfNeeded()
    #expect(releasedStore != nil)
    PrivateBrowserHost.retireHostingContent(hosting)
    for _ in 0..<100 {
      if releasedStore == nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(releasedStore == nil)
  }
}
