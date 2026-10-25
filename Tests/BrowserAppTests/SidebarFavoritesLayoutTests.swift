import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SidebarFavoritesLayoutTests: XCTestCase {
  private final class CaptureMeasurements {
    var footerFrame: CGRect?
    var favoriteRevealFrames = SidebarRevealFrames()
  }

  func testCapturesActualSidebarAcrossFavoriteCountsAndWindowSizes() async throws {
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-favorites", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dependencySHA = try gitHead()
    let sizes: [(String, CGFloat, CGFloat)] = [
      ("minimum-height", 240, 520), ("standard-height", 240, 760),
    ]
    let appearances: [(String, NSAppearance.Name, ColorScheme)] = [
      ("light", .aqua, .light), ("dark", .darkAqua, .dark),
    ]
    let favoriteCounts = [0, 1, 9, 50]
    var captures: [[String: Any]] = []

    for count in favoriteCounts {
      for (sizeName, width, height) in sizes {
        for (appearanceName, appearance, colorScheme) in appearances {
          let store = try makeStore(favoriteCount: count)
          let name = "favorites-\(count)-\(sizeName)-\(appearanceName).png"
          let path = root.appending(path: name)
          let measurements = CaptureMeasurements()
          let view = BrowserSidebar(store: store)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
            .onPreferenceChange(SidebarFooterBoundsPreferenceKey.self) {
              measurements.footerFrame = $0
            }
          let bounds = try await capture(
            view, size: NSSize(width: width, height: height), appearance: appearance,
            to: path, measurements: measurements)
          let footer = try XCTUnwrap(measurements.footerFrame, "Footer bounds missing: \(name)")
          XCTAssertGreaterThan(footer.width, 0, "Footer width missing: \(name)")
          XCTAssertGreaterThan(footer.height, 0, "Footer height missing: \(name)")
          let footerFits = footer.minY >= 0 && footer.maxY <= height
          XCTAssertTrue(footerFits, "Sidebar footer clipped: \(name), frame=\(footer)")
          captures.append([
            "path": path.path,
            "width": width,
            "height": height,
            "appearance": appearanceName,
            "favoriteCount": count,
            "selectedFavoriteID": count > 0 ? stableID(1000).uuidString : "none",
            "retainedFallbackID": stableID(300).uuidString,
            "capturePixelWidth": bounds.width,
            "capturePixelHeight": bounds.height,
            "footerBounds": [
              "x": footer.origin.x, "y": footer.origin.y,
              "width": footer.width, "height": footer.height,
            ],
            "footerFits": footerFits,
          ])
        }
      }
    }

    let proof: [String: Any] = [
      "dependencySHA": dependencySHA,
      "captures": captures,
      "favoriteCounts": favoriteCounts,
      "spaceName": String(repeating: "Long Space Label ", count: 5),
      "profileName": String(repeating: "Long Profile Label ", count: 5),
      "ordinaryAndPinnedTabs": 36,
      "selectedFavoriteID": favoriteCounts.map {
        $0 > 0 ? stableID(1000).uuidString : "none"
      },
      "retainedFallbackID": stableID(300).uuidString,
      "captureMethod":
        "BrowserSidebar hosted in hidden owned borderless NSWindow and NSHostingView",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: URL(fileURLWithPath: "/tmp/browser-sidebar-favorites-proof.json"), options: .atomic)
  }

  func testProgrammaticSelectionRevealsLastOwnedFavoriteWithBeforeAfterCaptures() async throws {
    let store = try makeStore(favoriteCount: 50, selectedFavoriteIndex: 49)
    let lastFavorite = try XCTUnwrap(store.profileFavorites.last)
    let firstFavorite = try XCTUnwrap(store.profileFavorites.first)
    let retainedTabID = try XCTUnwrap(store.session.selectedSpace.selectedTabID)
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-reveal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let measurements = CaptureMeasurements()
    let view = BrowserSidebar(store: store)
      .frame(width: 240, height: 520)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(
        \.browserChromeAccessibilityOverrides,
        BrowserChromeAccessibilityOverrides(reduceMotion: true)
      )
      .onPreferenceChange(SidebarFooterBoundsPreferenceKey.self) {
        measurements.footerFrame = $0
      }
      .onPreferenceChange(SidebarFavoriteRevealFramesPreferenceKey.self) {
        measurements.favoriteRevealFrames = $0
      }
    let mounted = try MountedFavoritesSidebar(
      view: view, size: NSSize(width: 240, height: 520), appearance: .aqua)
    defer { mounted.close() }
    guard
      await mounted.waitUntil({
        isVisible(measurements.favoriteRevealFrames, selectedID: lastFavorite.id)
      })
    else {
      XCTFail("Restored last owned Favorite not visible")
      return
    }
    let initialPath = root.appending(path: "favorite-initial-restored-last.png")
    try mounted.capture(to: initialPath)

    XCTAssertTrue(store.selectFavorite(firstFavorite.id))
    guard
      await mounted.waitUntil({
        isVisible(measurements.favoriteRevealFrames, selectedID: firstFavorite.id)
      })
    else {
      XCTFail(
        "Programmatically selected first Favorite not visible: \(measurements.favoriteRevealFrames)"
      )
      return
    }
    let firstPath = root.appending(path: "favorite-programmatic-first.png")
    try mounted.capture(to: firstPath)
    XCTAssertTrue(store.selectFavorite(lastFavorite.id))
    XCTAssertTrue(store.selectFavorite(firstFavorite.id))
    XCTAssertTrue(store.selectFavorite(lastFavorite.id))
    guard
      await mounted.waitUntil({
        guard case .favorite(let page) = store.session.selectedPage else { return false }
        return page.favoriteID == lastFavorite.id
          && isVisible(measurements.favoriteRevealFrames, selectedID: lastFavorite.id)
      })
    else {
      XCTFail("Programmatically selected last Favorite not visible after stale selection")
      return
    }
    let lastPath = root.appending(path: "favorite-programmatic-last.png")
    try mounted.capture(to: lastPath)
    XCTAssertFalse(store.selectFavorite(stableID(9999)))
    XCTAssertEqual(store.session.selectedSpace.selectedTabID, retainedTabID)
    guard case .favorite(let selectedPage) = store.session.selectedPage else {
      return XCTFail("Favorite selection fell back to ordinary tab")
    }
    XCTAssertEqual(selectedPage.favoriteID, lastFavorite.id)
    let captures: [[String: Any]] = [
      [
        "phase": "initial-restored-last", "path": initialPath.path,
        "selectedFavoriteID": lastFavorite.id.uuidString, "favoriteCount": 50,
      ],
      [
        "phase": "programmatic-first", "path": firstPath.path,
        "selectedFavoriteID": firstFavorite.id.uuidString, "favoriteCount": 50,
      ],
      [
        "phase": "programmatic-last", "path": lastPath.path,
        "selectedFavoriteID": lastFavorite.id.uuidString, "favoriteCount": 50,
      ],
    ]
    let index = try JSONSerialization.data(
      withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
    try index.write(to: root.appending(path: "favorite-capture-index.json"), options: .atomic)
  }

  private func makeStore(favoriteCount: Int, selectedFavoriteIndex: Int = 0) throws -> BrowserStore
  {
    let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let spaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let tabs = (0..<36).map { index in
      BrowserTab(
        id: stableID(300 + index),
        url: URL(string: "https://tab-\(index).example/path")!,
        title: "Tab \(index) with long title",
        isPinned: index > 0 && index < 13)
    }
    let favorites = (0..<favoriteCount).map { index in
      BrowserFavorite(
        id: stableID(1000 + index), profileID: profileID,
        originalURL: URL(string: "https://favorite-\(index).example/start")!,
        title: "Favorite \(index) with long title")
    }
    let pages = favorites.enumerated().map { index, favorite in
      BrowserFavoritePage(
        favoriteID: favorite.id,
        tab: BrowserTab(
          id: stableID(2000 + index),
          url: URL(string: "https://favorite-\(index).example/live")!,
          title: "Live favorite \(index)"))
    }
    let space = BrowserSpace(
      id: spaceID, profileID: profileID,
      name: String(repeating: "Long Space Label ", count: 5), symbol: "globe",
      tint: .ocean, tabs: tabs, selectedTabID: tabs[0].id,
      selectedFavoriteID: favorites.indices.contains(selectedFavoriteIndex)
        ? favorites[selectedFavoriteIndex].id : nil)
    let session = try BrowserSession(
      profiles: [
        BrowserProfile(id: profileID, name: String(repeating: "Long Profile Label ", count: 5))
      ],
      spaces: [space], selectedSpaceID: spaceID, favorites: favorites, favoritePages: pages)
    return BrowserStore(session: session)
  }

  private func stableID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", value))!
  }

  private func isVisible(_ frames: SidebarRevealFrames, selectedID: UUID) -> Bool {
    guard frames.selectedID == selectedID, !frames.selected.isEmpty, !frames.viewport.isEmpty
    else { return false }
    let visible = frames.selected.intersection(frames.viewport)
    return visible.width >= frames.selected.width - 0.5
      && visible.height >= frames.selected.height - 0.5
  }

  private func gitHead() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      value.count == 40
    else {
      throw NSError(domain: "SidebarFavoritesLayoutTests", code: 1)
    }
    return value
  }

  private func capture<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL,
    measurements: CaptureMeasurements
  ) async throws -> (width: Int, height: Int) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, size)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    XCTAssertEqual(bitmap.pixelsWide, Int(size.width))
    XCTAssertEqual(bitmap.pixelsHigh, Int(size.height))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
    XCTAssertNotNil(measurements.footerFrame)
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
  }
}

@MainActor
private final class MountedFavoritesSidebar {
  private let host: NSHostingView<AnyView>
  private let window: NSWindow

  init<V: View>(view: V, size: NSSize, appearance: NSAppearance.Name) throws {
    host = NSHostingView(rootView: AnyView(view))
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
  }

  func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 1)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func capture(to url: URL) throws {
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
  }

  func close() { window.close() }
}
