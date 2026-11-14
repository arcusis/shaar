// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarMediaPlayerTests {
  @Test func muteKeyboardFocusRevealsVolumeControl() {
    #expect(SidebarMediaPlayer.showsVolumeControl(pointerRevealed: false, keyboardFocused: true))
    #expect(SidebarMediaPlayer.showsVolumeControl(pointerRevealed: true, keyboardFocused: false))
    #expect(!SidebarMediaPlayer.showsVolumeControl(pointerRevealed: false, keyboardFocused: false))
  }

  @Test func voiceOverFocusOnMuteOrVolumeKeepsVolumeControlAvailable() {
    #expect(
      SidebarMediaPlayer.showsVolumeControl(
        pointerRevealed: false, keyboardFocused: false, accessibilityFocused: true))
    #expect(
      !SidebarMediaPlayer.showsVolumeControl(
        pointerRevealed: false, keyboardFocused: false, accessibilityFocused: false))
  }

  @Test func skipIgnoresUnsupportedAndNonSeekActions() {
    var commands: [MediaCommand] = []
    let player = SidebarMediaPlayer(
      item: MiniPlayerItem(
        tabID: UUID(), pageTitle: "Clip", favicon: nil,
        state: MediaSessionState(playbackState: .playing, actions: [.play, .pause])),
      onSelect: {}, onCommand: { commands.append($0) })

    player.skip(.seekBackward)
    player.skip(.seekForward)
    player.skip(.play)

    #expect(commands.isEmpty)
  }
}
