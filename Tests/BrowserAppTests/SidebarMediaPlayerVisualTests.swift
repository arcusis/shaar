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

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func testSidebarFooterShowsPlayerForHiddenPlayingTab() throws {
    var session = BrowserSession.fresh()
    let music = try XCTUnwrap(session.open(URL(string: "https://music.example")!))
    _ = try XCTUnwrap(session.open(URL(string: "https://reading.example")!))
    let store = BrowserStore(session: session)
    store.media.update(
      music,
      state: MediaSessionState(
        playbackState: .playing, title: "Night Drive", artist: "Arcusis Trio",
        actions: [.play, .pause, .previousTrack, .nextTrack]))
    let url = root.appending(path: "sidebar-footer.png")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let target = appearance == .aqua ? url : root.appending(path: "sidebar-footer-dark.png")
      try VisualCapture.renderOffscreen(
        BrowserSidebar(store: store).frame(width: 200, height: 520)
          .background(Color(nsColor: .windowBackgroundColor)),
        size: NSSize(width: 200, height: 520), appearance: appearance, to: target)
    }
    let lines = try VisualTextRecognition.lines(in: url)
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

  private func player(actions: Set<MediaSessionAction>, muted: Bool) -> SidebarMediaPlayer {
    SidebarMediaPlayer(
      item: MiniPlayerItem(
        tabID: UUID(), pageTitle: "Page",
        favicon: FaviconFixture.icon(NSColor(srgbRed: 0.86, green: 0.18, blue: 0.18, alpha: 1)),
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
}
