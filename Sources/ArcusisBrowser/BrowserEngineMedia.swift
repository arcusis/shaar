// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

extension BrowserEngine {
  func receiveMediaSession(_ identity: String, payload: [String: Any]?) {
    guard let id = ownedLiveTab(identity) else { return }
    store?.media.update(id, state: payload.flatMap(MediaSessionState.init(payload:)))
  }

  func performMedia(_ command: MediaCommand, tabID: UUID) -> Bool {
    guard let identity = ownedLiveTab(tabID.uuidString).map(\.uuidString) else { return false }
    switch command {
    case .perform(let action, let seconds):
      return runtime.sendMediaSessionAction(action.bridgeAction, seconds: seconds, tabID: identity)
    case .setMuted(let muted):
      return runtime.setMuted(muted, tabID: identity)
    }
  }

  /// A live tab that this window's engine owns.
  private func ownedLiveTab(_ identity: String) -> UUID? {
    guard !isClosed, runtime.windowID(forTabID: identity) == windowID,
      let id = UUID(uuidString: identity), liveTabs.contains(id)
    else { return nil }
    return id
  }
}

extension MediaSessionAction {
  var bridgeAction: ARCMediaSessionAction {
    switch self {
    case .play: .play
    case .pause: .pause
    case .previousTrack: .previousTrack
    case .nextTrack: .nextTrack
    case .seekBackward: .seekBackward
    case .seekForward: .seekForward
    case .seekTo: .seekTo
    }
  }
}
