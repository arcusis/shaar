// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// Live Media Session state for one window's tabs, and the tab the sidebar player controls.
@MainActor @Observable
final class MediaPlaybackModel {
  private(set) var sessions: [UUID: MediaSessionState] = [:]
  /// When each tab last started playing, as an increasing sequence number.
  private var lastStarted: [UUID: Int] = [:]
  private var startCount = 0

  func update(_ tabID: UUID, state: MediaSessionState?) {
    guard let state, state.playbackState != .none else {
      remove(tabID)
      return
    }
    if state.isPlaying && sessions[tabID]?.isPlaying != true {
      startCount += 1
      lastStarted[tabID] = startCount
    }
    if sessions[tabID] != state { sessions[tabID] = state }
  }

  func remove(_ tabID: UUID) {
    sessions[tabID] = nil
    lastStarted[tabID] = nil
  }

  func removeAll() {
    sessions.removeAll()
    lastStarted.removeAll()
  }

  /// A hidden tab that has played: a playing tab first, then the one that started most recently.
  /// Visible tabs are left to their pages; a tab that never played stays out of the player.
  func miniPlayerTabID(hiding visible: Set<UUID>) -> UUID? {
    sessions.keys
      .filter { !visible.contains($0) && lastStarted[$0] != nil }
      .max { rank($0) < rank($1) }
  }

  private func rank(_ tabID: UUID) -> (Int, Int) {
    (sessions[tabID]?.isPlaying == true ? 1 : 0, lastStarted[tabID] ?? 0)
  }
}
