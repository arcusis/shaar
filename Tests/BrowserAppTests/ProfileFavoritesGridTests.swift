// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileFavoritesGridTests: XCTestCase {
  private final class Measurements { var reveal = SidebarRevealFrames() }

  func testCapturesActualGridAtSidebarContentWidth() async throws {
    let profileID = UUID()
    let dragSessionID = UUID()
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath
        + "/build/Verification/sidebar-dnd/grid", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let cases: [(String, Int, ColorScheme, Bool, Bool, Bool)] =
      (1...12).flatMap { count in
        [ColorScheme.light, .dark].flatMap { scheme in
          [false, true].map { rtl in
            (
              "\(count)-\(scheme == .dark ? "dark" : "light")-\(rtl ? "he" : "en")",
              count, scheme, false, false, rtl
            )
          }
        }
      } + [
        ("zero", 0, .light, false, false, false),
        ("reduced-motion", 9, .light, true, false, false),
        ("reduced-transparency", 9, .light, false, true, false),
      ]
    var captures: [[String: Any]] = []

    for (name, count, scheme, reduceMotion, reduceTransparency, isRTL) in cases {
      let measurements = Measurements()
      let favorites = makeFavorites(count: count, includesLongValue: false, isRTL: isRTL)
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
      .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
      .environment(\.locale, Locale(identifier: isRTL ? "he" : "en"))
      .onPreferenceChange(SidebarFavoriteRevealFramesPreferenceKey.self) {
        measurements.reveal = $0
      }

      let imageURL = root.appending(path: "\(name).png")
      let naturalFittingSize = NSHostingView(rootView: view).fittingSize
      let captureView =
        count == 0
        ? AnyView(view.frame(width: 212, height: 24, alignment: .topLeading))
        : AnyView(view)
      let captured = try await capture(
        captureView, fittingSize: naturalFittingSize, hostHeight: count == 0 ? 24 : 282,
        to: imageURL, appearance: scheme == .dark ? .darkAqua : .aqua)
      XCTAssertEqual(captured.hostWidth, 212, accuracy: 0.5)
      XCTAssertLessThanOrEqual(captured.fittingWidth, 212.5)
      if count == 0 {
        XCTAssertEqual(captured.fittingHeight, 8, accuracy: 1)
      } else {
        XCTAssertGreaterThan(captured.fittingHeight, 0)
        XCTAssertLessThanOrEqual(captured.fittingHeight, 282)
      }
      XCTAssertLessThanOrEqual(captured.hostHeight, count == 0 ? 24 : 282)
      if count > 0 {
        XCTAssertNil(captured.scrollViewHeight)
        let rows = try XCTUnwrap(FavoritesGridLayout.rows(for: count)).count
        let expectedHeight = CGFloat(rows) * 44 + CGFloat(rows - 1) * 8 + 2
        XCTAssertEqual(captured.fittingHeight, expectedHeight, accuracy: 1)
        let expectedFrame = FavoritesGridLayout.frames(
          count: count, width: 212, isRightToLeft: isRTL)[0]
        XCTAssertEqual(measurements.reveal.selected.minX, expectedFrame.minX, accuracy: 1)
        XCTAssertEqual(measurements.reveal.selected.width, expectedFrame.width, accuracy: 1)
      }
      captures.append([
        "name": name,
        "favoriteCount": count,
        "colorScheme": scheme == .dark ? "dark" : "light",
        "reduceMotion": reduceMotion,
        "reduceTransparency": reduceTransparency,
        "language": isRTL ? "he" : "en",
        "rows": FavoritesGridLayout.rows(for: count) ?? [],
        "image": imageURL.path,
        "hostWidth": captured.hostWidth,
        "hostHeight": captured.hostHeight,
        "fittingWidth": captured.fittingWidth,
        "fittingHeight": captured.fittingHeight,
        "scrollViewHeight": captured.scrollViewHeight as Any? ?? NSNull(),
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

        "Physical drag input and full application runtime"
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: root.appending(path: "manifest.json"),
      options: .atomic)
  }

  func testOffscreenContactSheetsForPR() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "build/Verification/sidebar-dnd/grid")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for dark in [false, true] {
      for rtl in [false, true] {
        let view = VStack(spacing: 12) {
          ForEach(0..<4) { row in
            HStack(alignment: .top, spacing: 12) {
              ForEach(1..<4) { column in
                let count = row * 3 + column
                VStack(alignment: .leading, spacing: 8) {
                  Text(
                    "\(count) · \(FavoritesGridLayout.rows(for: count)!.map(String.init).joined(separator: " + "))"
                  )
                  .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                  ProfileFavoritesGrid(
                    favorites: self.makeFavorites(count: count, isRTL: rtl), selectedID: nil,
                    profileID: UUID(), dragSessionID: UUID(), onSelect: { _ in },
                    onReset: { _ in }, onRemove: { _ in }, onMoveBefore: { _, _ in })
                  Spacer(minLength: 0)
                }
                .frame(width: 212, height: 180, alignment: .topLeading)
                .padding(12)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
              }
            }
          }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: rtl ? "he" : "en"))
        let name = "favorites-1-12-\(dark ? "dark" : "light")-\(rtl ? "he" : "en").png"
        _ = try await capture(
          view, fittingSize: NSSize(width: 756, height: 876), hostHeight: 876,
          to: root.appending(path: name), hostWidth: 756, appearance: dark ? .darkAqua : .aqua)
      }
    }
  }

  func testBalancedRowsAndThirteenthRefused() {
    let expected = [
      [1], [2], [3], [4], [3, 2], [3, 3], [4, 3], [4, 4],
      [3, 3, 3], [4, 3, 3], [4, 4, 3], [4, 4, 4],
    ]
    for count in 1...12 {
      XCTAssertEqual(FavoritesGridLayout.rows(for: count), expected[count - 1])
      for rtl in [false, true] {
        let frames = FavoritesGridLayout.frames(count: count, width: 212, isRightToLeft: rtl)
        XCTAssertEqual(frames.count, count)
        for (index, frame) in frames.enumerated() {
          XCTAssertGreaterThanOrEqual(frame.minX, 0)
          XCTAssertLessThanOrEqual(frame.maxX, 212.5)
          XCTAssertEqual(
            FavoritesGridLayout.insertionIndex(
              at: CGPoint(x: frame.midX, y: frame.midY), count: count, width: 212, rtl: rtl), index)
        }
      }
    }
    XCTAssertNil(FavoritesGridLayout.rows(for: 13))
    XCTAssertEqual(BrowserSession.maximumFavoritesPerProfile, 12)
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

  private func makeFavorites(count: Int, includesLongValue: Bool = false, isRTL: Bool = false)
    -> [FavoriteTile]
  {
    (0..<count).map { index in
      let letter = String(UnicodeScalar((isRTL ? 0x05D0 : 65) + index)!)
      let title =
        includesLongValue && index == 0
        ? String(repeating: "Research and planning favorite ", count: 8)
        : "\(letter) \(isRTL ? "מועדף" : "Favorite")"
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
    _ view: V, fittingSize: NSSize, hostHeight: CGFloat, to imageURL: URL, hostWidth: CGFloat = 212,
    appearance: NSAppearance.Name = .aqua
  ) async throws -> (
    hostWidth: CGFloat, hostHeight: CGFloat, fittingWidth: CGFloat, fittingHeight: CGFloat,
    scrollViewHeight: CGFloat?
  ) {
    let size = NSSize(width: hostWidth, height: hostHeight)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: appearance)
    host.appearance = window.appearance
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)

    try await Task.sleep(for: .milliseconds(60))
    host.layoutSubtreeIfNeeded()
    let scrollView = findScrollView(in: host)
    scrollView?.layoutSubtreeIfNeeded()
    _ = try VisualCapture.render(
      host, to: imageURL)
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
