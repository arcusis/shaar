// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

/// Offscreen captures of the sidebar footer player. Nothing is ordered on screen.
@MainActor
final class SidebarMediaPlayerVisualTests: XCTestCase {
  private let root = URL(fileURLWithPath: "/tmp/shaar-sidebar-media-player", isDirectory: true)
  private let siteColor = NSColor(srgbRed: 0.86, green: 0.18, blue: 0.18, alpha: 1)

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func testSidebarFooterShowsPlayerForHiddenPlayingTab() throws {
    let support = FileManager.default.temporaryDirectory.appending(
      path: "media-player-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    var session = BrowserSession.fresh()
    let music = try XCTUnwrap(session.open(URL(string: "https://music.example")!))
    session.togglePin(music)
    _ = try XCTUnwrap(session.open(URL(string: "https://reading.example")!))
    let manager = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: support.appending(path: "workspace.json"),
        legacySessionURL: support.appending(path: "session.json")),
      initialSession: session,
      faviconCache: FaviconCache(directory: support.appending(path: "icons")))
    let store = try XCTUnwrap(manager.stores[manager.workspace.windows[0].id])
    store.rememberFavicon(FaviconFixture.icon(siteColor), forTab: music)
    store.media.update(
      music,
      state: MediaSessionState(
        playbackState: .playing, title: "Night Drive", artist: "Arcusis Trio",
        actions: [.play, .pause, .previousTrack, .nextTrack]))
    XCTAssertNotNil(store.miniPlayerItem?.favicon, "the player uses the tab's site icon")

    let size = NSSize(width: 200, height: 520)
    let light = root.appending(path: "sidebar-footer.png")
    let bitmaps = try [
      (NSAppearance.Name.aqua, light), (.darkAqua, root.appending(path: "sidebar-footer-dark.png")),
    ]
    .map { appearance, url in
      try VisualCapture.renderOffscreen(
        BrowserSidebar(store: store).frame(width: size.width, height: size.height)
          .background(Color(nsColor: .windowBackgroundColor)),
        size: size, appearance: appearance, to: url)
    }
    for bitmap in bitmaps {
      XCTAssertGreaterThan(
        sitePixels(in: bitmap, fromBottom: 140), 150, "site icon missing from the player")
    }
    let lines = try VisualTextRecognition.lines(in: light)
    XCTAssertTrue(lines.contains { $0.contains("Night Drive") }, "title missing: \(lines)")
    XCTAssertTrue(lines.contains { $0.contains("Arcusis Trio") }, "artist missing: \(lines)")
  }

  func testControlsFollowSupportedActions() throws {
    let full = player(actions: [.play, .pause, .previousTrack, .nextTrack], muted: false)
    let videoOnly = player(actions: [.play, .pause], muted: true)
    for (view, name) in [(full, "player-track-controls"), (videoOnly, "player-play-pause-only")] {
      try VisualCapture.renderOffscreen(
        view.padding(14).background(Color(nsColor: .windowBackgroundColor)),
        size: NSSize(width: 200, height: 92), appearance: .darkAqua,
        to: root.appending(path: "\(name).png"))
    }
    XCTAssertEqual(controlCount(full), 4)
    XCTAssertEqual(controlCount(videoOnly), 2, "play/pause and mute only")
  }

  func testExpandedVolumeFitsWithFullAndPlayPauseOnlyControls() throws {
    for actions: Set<MediaSessionAction> in [
      [.play, .pause, .previousTrack, .nextTrack], [.play, .pause],
    ] {
      for (appearance, scheme, name) in [
        (NSAppearance.Name.aqua, ColorScheme.light, "light"), (.darkAqua, .dark, "dark"),
      ] {
        let view = SidebarMediaPlayer(
          volumeIsVisible: true,
          item: MiniPlayerItem(
            tabID: UUID(), pageTitle: "Page", favicon: FaviconFixture.icon(siteColor),
            state: MediaSessionState(
              playbackState: .playing, title: "Night Drive", artist: "Arcusis Trio",
              actions: actions, volume: 0.35)),
          onSelect: {}, onCommand: { _ in })
        let bitmap = try VisualCapture.renderOffscreen(
          view.environment(\.colorScheme, scheme).padding(14)
            .background(Color(nsColor: .windowBackgroundColor)),
          size: NSSize(width: 200, height: 120), appearance: appearance,
          to: root.appending(path: "volume-\(actions.count)-\(name).png"))
        XCTAssertEqual(bitmap.pixelsWide, 200)
      }
    }
  }

  private func player(actions: Set<MediaSessionAction>, muted: Bool) -> SidebarMediaPlayer {
    SidebarMediaPlayer(
      item: MiniPlayerItem(
        tabID: UUID(), pageTitle: "Page",
        favicon: FaviconFixture.icon(siteColor),
        state: MediaSessionState(
          playbackState: .playing, title: "Night Drive", artist: "Arcusis Trio",
          actions: actions, muted: muted)),
      onSelect: {}, onCommand: { _ in })
  }

  /// Counts the transport buttons the player would draw for its state.
  private func controlCount(_ player: SidebarMediaPlayer) -> Int {
    let state = player.item.state
    return [
      state.supports(.previousTrack), state.playPauseAction != nil, state.supports(.nextTrack),
      true,
    ].filter { $0 }.count
  }

  /// Pixels of the site icon's color in the bottom rows, where the player sits.
  private func sitePixels(in bitmap: NSBitmapImageRep, fromBottom rows: Int) -> Int {
    guard let wanted = siteColor.usingColorSpace(.sRGB) else { return 0 }
    var count = 0
    for y in (bitmap.pixelsHigh - rows)..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let distance = max(
          abs(pixel.redComponent - wanted.redComponent),
          abs(pixel.greenComponent - wanted.greenComponent),
          abs(pixel.blueComponent - wanted.blueComponent))
        if distance < 0.08 { count += 1 }
      }
    }
    return count
  }
}
