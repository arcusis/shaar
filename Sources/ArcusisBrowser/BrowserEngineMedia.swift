// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

extension BrowserEngine {
  func receiveMediaSession(_ identity: String, payload: [String: Any]?) {
    guard let id = ownedLiveTab(identity) else { return }
    let state = payload.flatMap(MediaSessionState.init(payload:))
    store?.media.update(id, state: state)
    if pictureInPictureControls.tabID == id {
      pictureInPictureControls.update(state?.pictureInPicture)
    }
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

  /// Drops a tab's playback and picture-in-picture state.
  func forgetMedia(_ tabID: UUID) {
    store?.media.remove(tabID)
    autoPictureInPicture.forget(tabID)
    pictureInPictureControls.detach(from: tabID)
  }

  /// Opens picture-in-picture for pages that leave the screen and closes it for pages that
  /// return. Runs before native selection changes.
  func handOffPictureInPicture() {
    guard !isClosed, let store else { return }
    autoPictureInPicture.visiblePagesChanged(
      to: store.visiblePageIDs.intersection(liveTabs), sessions: store.media.sessions,
      allowed: { store.automaticPictureInPictureAllowed(forTab: $0) })
  }

  func receivePictureInPicture(_ identity: String, active: Bool) {
    guard let id = ownedLiveTab(identity) else { return }
    autoPictureInPicture.pictureInPictureChanged(id, active: active)
    if active {
      let identity = id.uuidString
      pictureInPictureControls.attach(
        tabID: id,
        finding: { [weak self] in self?.runtime.pictureInPictureVideoWindow(forTabID: identity) },
        video: { [weak self] in self?.store?.media.sessions[id]?.pictureInPicture })
    } else {
      pictureInPictureControls.detach(from: id)
    }
  }

  func performPictureInPicture(_ command: PictureInPictureControls.Command, tabID: UUID) {
    guard let identity = ownedLiveTab(tabID.uuidString)?.uuidString else { return }
    switch command {
    case .play:
      runtime.sendPictureInPictureCommand(.play, seconds: 0, tabID: identity)
    case .pause:
      runtime.sendPictureInPictureCommand(.pause, seconds: 0, tabID: identity)
    case .skip(let seconds):
      runtime.sendPictureInPictureCommand(.skip, seconds: seconds, tabID: identity)
    case .close:
      runtime.exitPictureInPicture(inTabID: identity)
    case .backToTab:
      runtime.exitPictureInPicture(inTabID: identity)
      showRequestedTab(identity)
    }
  }

  /// Back to Tab in the picture-in-picture window, or a page that focuses itself.
  func showRequestedTab(_ identity: String) {
    guard let id = ownedLiveTab(identity), let store else { return }
    store.selectPage(id)
    // Offscreen windows, such as verification hosts, are never ordered on screen.
    guard let window = runtime.window(forID: windowID), window.isVisible || window.isMiniaturized
    else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// A new page starts with its handler registered; withhold it when the site is turned off.
  func withholdAutomaticPictureInPictureIfOff(_ tabID: UUID, url: URL) {
    guard ownedLiveTab(tabID.uuidString) != nil, let store,
      let profileID = store.session.profileID(forTabID: tabID),
      !store.automaticPictureInPictureAllowed(for: url, profileID: profileID)
    else { return }
    runtime.setAutoPictureInPictureAllowed(false, tabID: tabID.uuidString)
  }

  func applyAutomaticPictureInPicture(site: String, profileID: UUID) {
    guard !isClosed, let store else { return }
    for tabID in liveTabs where store.session.profileID(forTabID: tabID) == profileID {
      guard let url = store.session.page(forTabID: tabID)?.tab.url,
        SiteSettingKey.site(for: url) == site
      else { continue }
      runtime.setAutoPictureInPictureAllowed(
        store.automaticPictureInPictureAllowed(for: url, profileID: profileID),
        tabID: tabID.uuidString)
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

extension AutoPictureInPicture.Engine {
  static func chromium(_ runtime: ARCChromiumRuntime) -> Self {
    Self(
      enter: { runtime.enterPictureInPicture(inTabID: $0.uuidString) { _ in } },
      exit: { runtime.exitPictureInPicture(inTabID: $0.uuidString) },
      handlesAutomatically: { runtime.engineHandlesAutoPictureInPicture(forTabID: $0.uuidString) })
  }
}
