// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FaviconCacheTests {
  private let profileID = UUID()
  private let itemID = UUID()

  @Test func storedIconIsAvailableImmediatelyAndAfterRestart() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    #expect(cache.icon(for: itemID, profileID: profileID) != nil)

    let restarted = FaviconCache(directory: directory)
    let icon = try #require(restarted.icon(for: itemID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .red))
  }

  @Test func newerIconReplacesTheStoredOne() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    cache.store(FaviconFixture.icon(.blue), for: itemID, profileID: profileID, host: "example.test")
    #expect(
      FaviconFixture.matches(try #require(cache.icon(for: itemID, profileID: profileID)), .blue))

    let restarted = FaviconCache(directory: directory)
    let icon = try #require(restarted.icon(for: itemID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .blue))
  }

  @Test func removedIconIsGoneAfterRestart() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    let keptID = UUID()
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    cache.store(FaviconFixture.icon(.blue), for: keptID, profileID: profileID, host: "example.test")
    cache.remove(itemID, profileID: profileID)
    #expect(cache.icon(for: itemID, profileID: profileID) == nil)

    let restarted = FaviconCache(directory: directory)
    #expect(restarted.icon(for: itemID, profileID: profileID) == nil)
    #expect(restarted.icon(for: keptID, profileID: profileID) != nil)
  }

  @Test func profilesKeepSeparateIcons() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let otherProfileID = UUID()
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    cache.store(
      FaviconFixture.icon(.blue), for: itemID, profileID: otherProfileID, host: "example.test")
    #expect(cache.icon(for: UUID(), profileID: profileID) == nil)
    #expect(cache.icon(for: itemID, profileID: UUID()) == nil)

    cache.remove(itemID, profileID: otherProfileID)
    let restarted = FaviconCache(directory: directory)
    let icon = try #require(restarted.icon(for: itemID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .red))
    #expect(restarted.icon(for: itemID, profileID: otherProfileID) == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appending(path: otherProfileID.uuidString).path))
  }

  @Test func retainDropsIconsOfRemovedItemsAndProfiles() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let deletedProfileID = UUID()
    let removedID = UUID()
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    cache.store(
      FaviconFixture.icon(.blue), for: removedID, profileID: profileID, host: "example.test")
    cache.store(
      FaviconFixture.icon(.red), for: itemID, profileID: deletedProfileID, host: "example.test")
    cache.retain([profileID: [itemID]])

    let restarted = FaviconCache(directory: directory)
    #expect(restarted.icon(for: itemID, profileID: profileID) != nil)
    #expect(restarted.icon(for: removedID, profileID: profileID) == nil)
    #expect(restarted.icon(for: itemID, profileID: deletedProfileID) == nil)
  }

  @Test func largeIconIsStoredAtTheFixedPixelSize() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red, side: 1024), for: itemID, profileID: profileID)
    let file = directory.appending(path: "\(profileID.uuidString)/\(itemID.uuidString).png")
    let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
    #expect(bitmap.pixelsWide == FaviconCache.pixelSide)
    #expect(bitmap.pixelsHigh == FaviconCache.pixelSide)
  }

  @Test func oversizedFileOnDiskIsIgnored() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profileDirectory = directory.appending(path: profileID.uuidString)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try Data(count: FaviconCache.maximumIconBytes + 1).write(
      to: profileDirectory.appending(path: "\(itemID.uuidString).png"))
    #expect(FaviconCache(directory: directory).icon(for: itemID, profileID: profileID) == nil)
  }

  @Test func profileDirectorySymlinkIsNeitherReadFromNorWrittenThrough() throws {
    let directory = temporaryDirectory()
    let outside = directory.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID, host: "example.test")
    let profileDirectory = directory.appending(
      path: profileID.uuidString, directoryHint: .isDirectory)
    try FileManager.default.moveItem(
      at: profileDirectory, to: outside.appending(path: profileID.uuidString))
    try FileManager.default.createSymbolicLink(
      at: profileDirectory, withDestinationURL: outside.appending(path: profileID.uuidString))

    let redirected = FaviconCache(directory: directory)
    #expect(redirected.icon(for: itemID, profileID: profileID) == nil)
    let otherItemID = UUID()
    redirected.store(
      FaviconFixture.icon(.blue), for: otherItemID, profileID: profileID, host: "example.test")
    #expect(
      !FileManager.default.fileExists(
        atPath: outside.appending(path: "\(profileID.uuidString)/\(otherItemID.uuidString).png")
          .path))
    #expect(
      FileManager.default.fileExists(
        atPath: outside.appending(path: "\(profileID.uuidString)/\(itemID.uuidString).png").path))
  }

  @Test func workspaceKeepsPinnedAndFavoriteIconsOnly() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, favoriteID, pinnedID, ordinaryID) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let window = manager.workspace.windows[0]
    let store = try #require(manager.stores[window.id])
    let favorite = try #require(store.session.favorites.first { $0.id == favoriteID })
    let pageID = try #require(store.session.favoritePage(for: favoriteID)?.tab.id)
    let pinID = try #require(window.pins.first { $0.tabID == pinnedID }?.pinID)

    store.rememberFavicon(FaviconFixture.icon(.red), forTab: pageID, host: "favorite.example")
    store.rememberFavicon(FaviconFixture.icon(.blue), forTab: pinnedID, host: "pinned.example")
    store.rememberFavicon(FaviconFixture.icon(.red), forTab: ordinaryID, host: "ordinary.example")
    #expect(cache.icon(for: favoriteID, profileID: profileID) != nil)
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    #expect(cache.icon(for: ordinaryID, profileID: profileID) == nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: ordinaryID))
    let pinned = try #require(store.session.page(forTabID: pinnedID)?.tab)
    #expect(store.favicon(for: favorite).map { FaviconFixture.matches($0, .red) } == true)
    #expect(
      store.favicon(for: pinned, profileID: profileID).map { FaviconFixture.matches($0, .blue) }
        == true)

    #expect(store.removeFavorite(favoriteID))
    store.togglePin(pinnedID)
    let restarted = FaviconCache(directory: directory)
    #expect(restarted.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(restarted.icon(for: pinID, profileID: profileID) != nil)
    #expect(restarted.icon(for: ordinaryID, profileID: profileID) == nil)
  }

  @Test func pinnedTabIconIsSharedWithNewWindows() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, pinnedID, _) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let manager = try BrowserWorkspaceStore(
      initialSession: session, faviconCache: FaviconCache(directory: directory))
    let firstID = manager.workspace.windows[0].id
    let first = try #require(manager.stores[firstID])
    first.rememberFavicon(FaviconFixture.icon(.blue), forTab: pinnedID)

    let secondID = try manager.newWindow(from: firstID)
    try manager.removeWindow(firstID)
    let second = try #require(manager.stores[secondID])
    let pinned = try #require(second.session.selectedSpace.tabs.first { $0.isPinned })
    #expect(pinned.id != pinnedID)
    #expect(
      second.favicon(for: pinned, profileID: profileID).map { FaviconFixture.matches($0, .blue) }
        == true)
  }

  @Test func pinningLoadedTabCachesItsLiveIconAndRetainsIt() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://pinned.example")!)
    let tabID = try #require(session.selectedPage?.tab.id)
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let window = manager.workspace.windows[0]
    let store = try #require(manager.stores[window.id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    engine.seedFavicon(FaviconFixture.icon(.blue), for: tabID)

    store.togglePin(tabID)
    let pinID = try #require(manager.workspace.windows[0].pins.first?.pinID)
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    store.perform(.open(URL(string: "https://another.example")!))
    let restarted = FaviconCache(directory: directory)
    let icon = try #require(restarted.icon(for: pinID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .blue))
  }

  @Test func favoritingLoadedTabCachesItsLiveIcon() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://favorite.example")!)
    let tabID = try #require(session.selectedPage?.tab.id)
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let window = manager.workspace.windows[0]
    let store = try #require(manager.stores[window.id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    engine.seedFavicon(FaviconFixture.icon(.red), for: tabID)

    #expect(store.addCurrentPageAsFavorite())
    let favorite = try #require(store.session.selectedFavorite)
    let icon = try #require(cache.icon(for: favorite.id, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .red))
  }

  @Test func pinningCopiesACachedIconWhenTheLiveIconIsGone() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://pinned.example")!)
    let tabID = try #require(session.selectedPage?.tab.id)
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    cache.store(
      FaviconFixture.icon(.blue), for: tabID, profileID: profileID, host: "pinned.example")

    store.togglePin(tabID)
    let pinID = try #require(manager.workspace.windows[0].pins.first?.pinID)
    #expect(pinID != tabID)
    let icon = try #require(cache.icon(for: pinID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .blue))
    let pinned = try #require(store.session.page(forTabID: tabID)?.tab)
    #expect(
      store.favicon(for: pinned, profileID: profileID).map { FaviconFixture.matches($0, .blue) }
        == true)
  }

  @Test func unpinningDoesNotPersistTheIconOnTheOrdinaryTab() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://pinned.example")!)
    let tabID = try #require(session.selectedPage?.tab.id)
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    store.togglePin(tabID)
    let pinID = try #require(manager.workspace.windows[0].pins.first?.pinID)
    store.rememberFavicon(FaviconFixture.icon(.blue), forTab: tabID)
    cache.remove(tabID, profileID: profileID)

    store.togglePin(tabID)
    #expect(cache.icon(for: tabID, profileID: profileID) == nil)
    #expect(pinID != tabID)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: tabID))
  }

  @Test func movingAnOrdinaryTabDoesNotWriteAFavicon() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    let opened = session.open(URL(string: "https://ordinary.example")!)
    let tabID = try #require(opened)
    let profileID = session.selectedSpace.profileID
    let source = session.selectedSpaceID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    engine.noteDocumentFavicon(FaviconFixture.icon(.blue), for: tabID, host: "ordinary.example")
    #expect(engine.favicons[tabID] != nil)
    #expect(cache.icon(for: tabID, profileID: profileID) == nil)

    #expect(store.createSpace(name: "Shared", sharingProfile: profileID, tint: .ocean))
    #expect(store.moveTab(tabID, from: source, to: store.session.selectedSpaceID))
    #expect(cache.icon(for: tabID, profileID: profileID) == nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: tabID))
  }

  @Test func droppingACachedTabOnFavoritesKeepsTheIcon() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://favorite.example")!)
    let tabID = try #require(session.selectedPage?.tab.id)
    let profileID = session.selectedSpace.profileID
    let space = session.selectedSpaceID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    cache.store(
      FaviconFixture.icon(.red), for: tabID, profileID: profileID, host: "favorite.example")

    #expect(
      store.acceptFavoritesDrop(
        .tab(sessionID: store.dragSessionID, sourceSpaceID: space, tabID: tabID)))
    let favorite = try #require(store.session.favorites.first)
    let icon = try #require(cache.icon(for: favorite.id, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .red))
    #expect(
      store.favicon(for: favorite).map { FaviconFixture.matches($0, .red) } == true)
  }

  @Test func hostChangeRemovesTheSavedPinFavoriteAndOrdinaryIcon() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, favoriteID, pinnedID, ordinaryID) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    let favoriteTab = try #require(store.session.favoritePage(for: favoriteID)?.tab.id)
    let pinID = try #require(
      manager.workspace.windows[0].pins.first { $0.tabID == pinnedID }?.pinID)
    let icon = FaviconFixture.icon(.blue)

    engine.noteDocumentFavicon(icon, for: pinnedID, host: "pinned.example")
    let written = try #require(Self.iconModified(directory, profileID: profileID, itemID: pinID))
    engine.noteDocumentFavicon(icon, for: pinnedID, host: "pinned.example")
    #expect(Self.iconModified(directory, profileID: profileID, itemID: pinID) == written)
    engine.noteDocumentFavicon(nil, for: pinnedID, host: "pinned.example")
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    #expect(engine.favicons[pinnedID] != nil)
    engine.noteDocumentFavicon(nil, for: pinnedID, host: "other.example")
    #expect(cache.icon(for: pinID, profileID: profileID) == nil)
    #expect(engine.favicons[pinnedID] == nil)

    engine.noteDocumentFavicon(icon, for: favoriteTab, host: "favorite.example")
    #expect(cache.icon(for: favoriteID, profileID: profileID) != nil)
    engine.noteDocumentFavicon(nil, for: favoriteTab, host: "other.example")
    #expect(cache.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(engine.favicons[favoriteTab] == nil)

    store.rememberFavicon(icon, forTab: ordinaryID, host: "ordinary.example")
    engine.noteDocumentFavicon(icon, for: ordinaryID, host: "ordinary.example")
    #expect(cache.icon(for: ordinaryID, profileID: profileID) == nil)
    #expect(engine.favicons[ordinaryID] != nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: ordinaryID))
    engine.noteDocumentFavicon(nil, for: ordinaryID, host: "other.example")
    #expect(cache.icon(for: ordinaryID, profileID: profileID) == nil)
    #expect(engine.favicons[ordinaryID] == nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: ordinaryID))
  }

  @Test func loadingTickUpdatesTheLiveIconWithoutWritingOrClearing() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, pinnedID, _) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    let pinID = try #require(
      manager.workspace.windows[0].pins.first { $0.tabID == pinnedID }?.pinID)
    let icon = FaviconFixture.icon(.blue)

    engine.noteDocumentFavicon(icon, for: pinnedID, host: "pinned.example", loading: true)
    #expect(engine.favicons[pinnedID] != nil)
    #expect(cache.icon(for: pinID, profileID: profileID) == nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: pinID))

    engine.noteDocumentFavicon(icon, for: pinnedID, host: "pinned.example")
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    let written = try #require(Self.iconModified(directory, profileID: profileID, itemID: pinID))
    engine.noteDocumentFavicon(icon, for: pinnedID, host: "pinned.example", loading: true)
    #expect(Self.iconModified(directory, profileID: profileID, itemID: pinID) == written)

    engine.noteDocumentFavicon(nil, for: pinnedID, host: "other.example", loading: true)
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    #expect(engine.favicons[pinnedID] != nil)
    #expect(Self.iconFileExists(directory, profileID: profileID, itemID: pinID))
  }

  @Test func freshEngineClearsAStalePinAndFavoriteWhenTheHostDiffers() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, favoriteID, pinnedID, _) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    let favoriteTab = try #require(store.session.favoritePage(for: favoriteID)?.tab.id)
    let pinID = try #require(
      manager.workspace.windows[0].pins.first { $0.tabID == pinnedID }?.pinID)
    let icon = FaviconFixture.icon(.blue)

    engine.noteDocumentFavicon(icon, for: pinnedID, host: "a.example")
    engine.noteDocumentFavicon(icon, for: favoriteTab, host: "a.example")
    #expect(cache.host(for: pinID, profileID: profileID) == "a.example")
    #expect(cache.host(for: favoriteID, profileID: profileID) == "a.example")

    let reloaded = FaviconCache(directory: directory)
    let restarted = try BrowserWorkspaceStore(
      initialSession: store.session, faviconCache: reloaded)
    let freshStore = try #require(restarted.stores[restarted.workspace.windows[0].id])
    let freshFavoriteTab = try #require(freshStore.session.favoritePage(for: favoriteID)?.tab.id)
    let fresh = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: freshStore)
    #expect(reloaded.host(for: pinID, profileID: profileID) == "a.example")
    #expect(reloaded.host(for: favoriteID, profileID: profileID) == "a.example")
    #expect(fresh.favicons[pinnedID] == nil)
    #expect(fresh.favicons[freshFavoriteTab] == nil)

    fresh.noteDocumentFavicon(nil, for: pinnedID, host: "b.example")
    fresh.noteDocumentFavicon(nil, for: freshFavoriteTab, host: "b.example")
    #expect(reloaded.icon(for: pinID, profileID: profileID) == nil)
    #expect(reloaded.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(reloaded.host(for: pinID, profileID: profileID) == nil)
    #expect(reloaded.host(for: favoriteID, profileID: profileID) == nil)
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: pinID))
    #expect(!Self.iconFileExists(directory, profileID: profileID, itemID: favoriteID))
  }

  @Test func legacyIconWithoutAHostFileStaysClearedOnAFreshEngine() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, favoriteID, pinnedID, _) = sidebarSession()
    let profileID = session.selectedSpace.profileID
    let cache = FaviconCache(directory: directory)
    let manager = try BrowserWorkspaceStore(initialSession: session, faviconCache: cache)
    let store = try #require(manager.stores[manager.workspace.windows[0].id])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    let favoriteTab = try #require(store.session.favoritePage(for: favoriteID)?.tab.id)
    let pinID = try #require(
      manager.workspace.windows[0].pins.first { $0.tabID == pinnedID }?.pinID)
    let icon = FaviconFixture.icon(.blue)

    engine.noteDocumentFavicon(icon, for: pinnedID, host: "a.example")
    engine.noteDocumentFavicon(icon, for: favoriteTab, host: "a.example")
    for itemID in [pinID, favoriteID] {
      try FileManager.default.removeItem(
        at: directory.appending(path: "\(profileID.uuidString)/\(itemID.uuidString).host"))
    }

    let reloaded = FaviconCache(directory: directory)
    let restarted = try BrowserWorkspaceStore(
      initialSession: store.session, faviconCache: reloaded)
    let freshStore = try #require(restarted.stores[restarted.workspace.windows[0].id])
    let freshFavoriteTab = try #require(freshStore.session.favoritePage(for: favoriteID)?.tab.id)
    let fresh = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: freshStore)
    #expect(reloaded.icon(for: pinID, profileID: profileID) == nil)
    #expect(reloaded.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(fresh.favicons[pinnedID] == nil)
    #expect(fresh.favicons[freshFavoriteTab] == nil)

    fresh.noteDocumentFavicon(nil, for: pinnedID, host: "b.example")
    fresh.noteDocumentFavicon(nil, for: freshFavoriteTab, host: "b.example")
    #expect(reloaded.icon(for: pinID, profileID: profileID) == nil)
    #expect(reloaded.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(Self.iconFileExists(directory, profileID: profileID, itemID: pinID))
    #expect(Self.iconFileExists(directory, profileID: profileID, itemID: favoriteID))
  }

  private static func iconFile(_ directory: URL, profileID: UUID, itemID: UUID) -> URL {
    directory.appending(path: "\(profileID.uuidString)/\(itemID.uuidString).png")
  }

  private static func iconFileExists(_ directory: URL, profileID: UUID, itemID: UUID) -> Bool {
    FileManager.default.fileExists(
      atPath: iconFile(directory, profileID: profileID, itemID: itemID).path)
  }

  private static func iconModified(_ directory: URL, profileID: UUID, itemID: UUID) -> Date? {
    try? iconFile(directory, profileID: profileID, itemID: itemID)
      .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  private func sidebarSession() -> (
    session: BrowserSession, favoriteID: UUID, pinnedID: UUID, ordinaryID: UUID
  ) {
    var session = BrowserSession.fresh()
    let favoriteID = session.addFavorite(
      profileID: session.selectedSpace.profileID,
      originalURL: URL(string: "https://favorite.example")!)!
    let pinnedID = session.open(URL(string: "https://pinned.example")!)!
    session.togglePin(pinnedID)
    let ordinaryID = session.open(URL(string: "https://ordinary.example")!)!
    return (session, favoriteID, pinnedID, ordinaryID)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "favicons-\(UUID().uuidString)")
  }
}

/// Solid-color icons for cache and capture tests. Cached icons are sRGB, so raw components compare.
@MainActor
enum FaviconFixture {
  static func icon(_ color: NSColor, side: CGFloat = 16) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      color.setFill()
      rect.fill()
      return true
    }
  }

  static func matches(_ image: NSImage, _ expected: NSColor) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let actual = NSBitmapImageRep(cgImage: cgImage).colorAt(
        x: cgImage.width / 2, y: cgImage.height / 2),
      let wanted = expected.usingColorSpace(.sRGB)
    else { return false }
    return abs(actual.redComponent - wanted.redComponent) < 0.05
      && abs(actual.greenComponent - wanted.greenComponent) < 0.05
      && abs(actual.blueComponent - wanted.blueComponent) < 0.05
  }
}
