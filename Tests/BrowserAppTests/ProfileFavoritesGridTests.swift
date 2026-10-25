import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileFavoritesGridTests: XCTestCase {
  func testCapturesActualGridAtSidebarContentWidth() async throws {
    let profileID = UUID()
    let dragSessionID = UUID()
    let root = URL(
      fileURLWithPath: "/tmp/browser-profile-favorites-grid-corrected", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let cases: [(String, Int, ColorScheme, Bool, Bool, Bool)] = [
      ("zero-light", 0, .light, false, false, false),
      ("one-light", 1, .light, false, false, true),
      ("nine-light", 9, .light, false, false, false),
      ("fifty-light", 50, .light, false, false, false),
      ("nine-long-title-url", 9, .light, false, false, true),
      ("nine-dark", 9, .dark, false, false, false),
      ("nine-reduced-motion", 9, .light, true, false, false),
      ("nine-reduced-transparency", 9, .light, false, true, false),
    ]
    var captures: [[String: Any]] = []

    for (name, count, scheme, reduceMotion, reduceTransparency, includesLongValue) in cases {
      let favorites = makeFavorites(count: count, includesLongValue: includesLongValue)
      let view = ProfileFavoritesGrid(
        favorites: favorites,
        selectedID: favorites.first?.id,
        profileID: profileID,
        dragSessionID: dragSessionID,
        onSelect: { _ in },
        onReset: { _ in },
        onRemove: { _ in },
        onMoveBefore: { _, _ in },
        accessibilityOverrides: ProfileFavoritesAccessibilityOverrides(
          reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
      )
      .frame(width: 212, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)

      let imageURL = root.appending(path: "\(name).png")
      let naturalFittingSize = NSHostingView(rootView: view).fittingSize
      let captureView =
        count == 0
        ? AnyView(view.frame(width: 212, height: 24, alignment: .topLeading))
        : AnyView(view)
      let measurements = try await capture(
        captureView, fittingSize: naturalFittingSize, hostHeight: count == 0 ? 24 : 212,
        to: imageURL)
      XCTAssertEqual(measurements.hostWidth, 212, accuracy: 0.5)
      XCTAssertLessThanOrEqual(measurements.fittingWidth, 212.5)
      if count == 0 {
        XCTAssertLessThanOrEqual(measurements.fittingHeight, 1)
      } else {
        XCTAssertGreaterThan(measurements.fittingHeight, 0)
        XCTAssertLessThanOrEqual(measurements.fittingHeight, 212)
      }
      XCTAssertLessThanOrEqual(measurements.hostHeight, count == 0 ? 24 : 212)
      if count > 0 {
        XCTAssertNotNil(measurements.scrollViewHeight)
        XCTAssertLessThanOrEqual(measurements.scrollViewHeight ?? .infinity, 164)
      }
      if includesLongValue {
        XCTAssertGreaterThan(favorites[0].title.count, 100)
        XCTAssertGreaterThan(favorites[0].url.absoluteString.count, 100)
      }
      captures.append([
        "name": name,
        "favoriteCount": count,
        "colorScheme": scheme == .dark ? "dark" : "light",
        "reduceMotion": reduceMotion,
        "reduceTransparency": reduceTransparency,
        "includesLongValue": includesLongValue,
        "image": imageURL.path,
        "hostWidth": measurements.hostWidth,
        "hostHeight": measurements.hostHeight,
        "fittingWidth": measurements.fittingWidth,
        "fittingHeight": measurements.fittingHeight,
        "scrollViewHeight": measurements.scrollViewHeight as Any? ?? NSNull(),
      ])
    }

    let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let report: [String: Any] = [
      "component": workspace.appending(path: "Sources/ArcusisBrowser/ProfileFavoritesGrid.swift")
        .path,
      "test": workspace.appending(path: "Tests/BrowserAppTests/ProfileFavoritesGridTests.swift")
        .path,
      "captureDirectory": root.path,
      "captures": captures,
      "unverified": [
        "Sidebar integration and placement above Space title",
        "Store adapter behavior and exact Store API acceptance",
        "Physical drag input and full application runtime",
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: URL(fileURLWithPath: "/tmp/browser-profile-favorites-grid-corrected-proof.json"),
      options: .atomic)
  }

  func testTypedDropValidatesBoundariesAndRejectsStaleForeignOrNoOpMoves() throws {
    let profileID = UUID()
    let dragSessionID = UUID()
    let favorites = makeFavorites(count: 3)
    let sourceID = favorites[2].id
    let validPayload = ProfileFavoriteDrag(
      profileID: profileID,
      dragSessionID: dragSessionID,
      favoriteID: sourceID,
      favoriteIDs: favorites.map(\.id))

    let width: CGFloat = 66
    XCTAssertEqual(
      ProfileFavoritesGrid.dropTargetBefore(
        targetID: favorites[0].id, dropX: 4, tileWidth: width, favorites: favorites),
      favorites[0].id)
    XCTAssertEqual(
      ProfileFavoritesGrid.dropTargetBefore(
        targetID: favorites[0].id, dropX: 60, tileWidth: width, favorites: favorites),
      favorites[1].id)
    XCTAssertNil(
      ProfileFavoritesGrid.dropTargetBefore(
        targetID: favorites[2].id, dropX: 60, tileWidth: width, favorites: favorites))

    XCTAssertTrue(
      ProfileFavoritesGrid.accepts(
        validPayload, before: favorites[0].id, favorites: favorites,
        profileID: profileID, dragSessionID: dragSessionID))
    let moveToEndPayload = ProfileFavoriteDrag(
      profileID: profileID,
      dragSessionID: dragSessionID,
      favoriteID: favorites[0].id,
      favoriteIDs: favorites.map(\.id))
    XCTAssertTrue(
      ProfileFavoritesGrid.accepts(
        moveToEndPayload, before: nil, favorites: favorites,
        profileID: profileID, dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        validPayload, before: nil, favorites: favorites,
        profileID: profileID, dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        moveToEndPayload, before: favorites[1].id, favorites: favorites,
        profileID: profileID, dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        ProfileFavoriteDrag(
          profileID: UUID(), dragSessionID: dragSessionID,
          favoriteID: sourceID, favoriteIDs: favorites.map(\.id)),
        before: favorites[0].id, favorites: favorites, profileID: profileID,
        dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        ProfileFavoriteDrag(
          profileID: profileID, dragSessionID: UUID(),
          favoriteID: sourceID, favoriteIDs: favorites.map(\.id)),
        before: favorites[0].id, favorites: favorites, profileID: profileID,
        dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        ProfileFavoriteDrag(
          profileID: profileID, dragSessionID: dragSessionID,
          favoriteID: sourceID, favoriteIDs: [favorites[1].id, favorites[0].id, favorites[2].id]),
        before: favorites[0].id, favorites: favorites, profileID: profileID,
        dragSessionID: dragSessionID))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        ProfileFavoriteDrag(
          profileID: profileID, dragSessionID: dragSessionID,
          favoriteID: sourceID, favoriteIDs: favorites.map(\.id)),
        before: sourceID, favorites: favorites, profileID: profileID,
        dragSessionID: dragSessionID))

    let adjacentPayload = ProfileFavoriteDrag(
      profileID: profileID,
      dragSessionID: dragSessionID,
      favoriteID: favorites[0].id,
      favoriteIDs: favorites.map(\.id))
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        adjacentPayload, before: favorites[1].id, favorites: favorites,
        profileID: profileID, dragSessionID: dragSessionID))

    let staleFavorites = Array(favorites.dropLast())
    XCTAssertFalse(
      ProfileFavoritesGrid.accepts(
        validPayload, before: favorites[0].id, favorites: staleFavorites,
        profileID: profileID, dragSessionID: dragSessionID))
  }

  private func makeFavorites(count: Int, includesLongValue: Bool = false) -> [FavoriteTile] {
    (0..<count).map { index in
      let title =
        includesLongValue && index == 0
        ? String(repeating: "Research and planning favorite ", count: 8)
        : "Favorite \(index + 1)"
      let address =
        includesLongValue && index == 0
        ? "https://\(String(repeating: "long-subdomain-", count: 10))example.com/\(String(repeating: "a-long-path-segment/", count: 8))?query=extended-value"
        : "https://favorite-\(index + 1).example"
      let image =
        index == 0 ? NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) : nil
      return FavoriteTile(
        id: UUID(), title: title, url: URL(string: address)!, image: image)
    }
  }

  private func capture<V: View>(
    _ view: V, fittingSize: NSSize, hostHeight: CGFloat, to imageURL: URL
  ) async throws -> (
    hostWidth: CGFloat, hostHeight: CGFloat, fittingWidth: CGFloat, fittingHeight: CGFloat,
    scrollViewHeight: CGFloat?
  ) {
    let size = NSSize(width: 212, height: hostHeight)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(60))
    host.layoutSubtreeIfNeeded()
    let scrollView = findScrollView(in: host)
    scrollView?.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: imageURL, options: .atomic)
    return (
      host.bounds.width, host.bounds.height, fittingSize.width, fittingSize.height,
      scrollView?.frame.height
    )
  }

  private func findScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for child in view.subviews {
      if let scrollView = findScrollView(in: child) { return scrollView }
    }
    return nil
  }
}
