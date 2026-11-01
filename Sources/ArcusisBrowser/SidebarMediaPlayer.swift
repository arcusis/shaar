// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

/// Compact controls for media playing in a tab that is not on screen. Track and play/pause
/// buttons appear only for actions the page supports; mute uses the engine's tab mute.
struct SidebarMediaPlayer: View {
  let item: MiniPlayerItem
  let onSelect: () -> Void
  let onCommand: (MediaCommand) -> Void

  private var state: MediaSessionState { item.state }

  private var title: String {
    state.title.isEmpty ? item.pageTitle : state.title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      pageButton
      HStack(spacing: 2) {
        if state.supports(.previousTrack) {
          control("backward.fill", label: "Previous track", id: "previous") {
            onCommand(.perform(.previousTrack))
          }
        }
        if let playPause = state.playPauseAction {
          control(
            playPause == .pause ? "pause.fill" : "play.fill",
            label: playPause == .pause ? "Pause" : "Play", id: "play-pause"
          ) {
            onCommand(.perform(playPause))
          }
        }
        if state.supports(.nextTrack) {
          control("forward.fill", label: "Next track", id: "next") {
            onCommand(.perform(.nextTrack))
          }
        }
        Spacer(minLength: 0)
        control(
          state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
          label: state.muted ? "Unmute" : "Mute", id: "mute"
        ) {
          onCommand(.setMuted(!state.muted))
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Now playing: \(title)")
    .accessibilityIdentifier("sidebar-media-player")
  }

  private var pageButton: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        siteIcon
        VStack(alignment: .leading, spacing: 0) {
          Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
          if !state.artist.isEmpty {
            Text(state.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show the playing tab")
    .accessibilityLabel("Show \(title)")
    .accessibilityIdentifier("sidebar-media-select")
  }

  @ViewBuilder private var siteIcon: some View {
    if let favicon = item.favicon {
      Image(nsImage: favicon).resizable().scaledToFit().frame(width: 16, height: 16)
    } else {
      Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
  }

  private func control(
    _ symbol: String, label: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12))
        .foregroundStyle(Color.primary.opacity(0.7))
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier("sidebar-media-\(id)")
  }
}
