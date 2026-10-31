// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
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
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID)
    #expect(cache.icon(for: itemID, profileID: profileID) != nil)

    let restarted = FaviconCache(directory: directory)
    let icon = try #require(restarted.icon(for: itemID, profileID: profileID))
    #expect(FaviconFixture.matches(icon, .red))
  }

  @Test func newerIconReplacesTheStoredOne() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID)
    cache.store(FaviconFixture.icon(.blue), for: itemID, profileID: profileID)
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
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID)
    cache.store(FaviconFixture.icon(.blue), for: keptID, profileID: profileID)
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
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID)
    cache.store(FaviconFixture.icon(.blue), for: itemID, profileID: otherProfileID)
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
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: profileID)
    cache.store(FaviconFixture.icon(.blue), for: removedID, profileID: profileID)
    cache.store(FaviconFixture.icon(.red), for: itemID, profileID: deletedProfileID)
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

  @Test func workspaceKeepsIconsOnlyForFavoritesAndPinnedTabs() throws {
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

    store.rememberFavicon(FaviconFixture.icon(.red), forTab: pageID)
    store.rememberFavicon(FaviconFixture.icon(.blue), forTab: pinnedID)
    store.rememberFavicon(FaviconFixture.icon(.red), forTab: ordinaryID)
    #expect(cache.icon(for: favoriteID, profileID: profileID) != nil)
    #expect(cache.icon(for: pinID, profileID: profileID) != nil)
    #expect(cache.icon(for: ordinaryID, profileID: profileID) == nil)
    let pinned = try #require(store.session.page(forTabID: pinnedID)?.tab)
    #expect(store.favicon(for: favorite).map { FaviconFixture.matches($0, .red) } == true)
    #expect(
      store.favicon(for: pinned, profileID: profileID).map { FaviconFixture.matches($0, .blue) }
        == true)

    #expect(store.removeFavorite(favoriteID))
    store.togglePin(pinnedID)
    let restarted = FaviconCache(directory: directory)
    #expect(restarted.icon(for: favoriteID, profileID: profileID) == nil)
    #expect(restarted.icon(for: pinID, profileID: profileID) == nil)
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
