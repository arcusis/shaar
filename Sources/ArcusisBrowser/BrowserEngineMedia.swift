// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import ShaarEngineABI

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
    if mediaImplementation == .shaar {
      return performShaarMedia(command, tabID: tabID)
    }
    switch command {
    case .perform(let action, let seconds):
      return runtime.sendMediaSessionAction(action.bridgeAction, seconds: seconds, tabID: identity)
    case .setMuted(let muted):
      return runtime.setMuted(muted, tabID: identity)
    case .setVolume(let volume):
      return runtime.setMediaVolume(volume, tabID: identity)
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
      guard mediaImplementation == .ardia else { return }
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
    if mediaImplementation == .shaar {
      performShaarPictureInPicture(command, tabID: tabID)
      return
    }
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
    if mediaImplementation == .shaar {
      updateShaarAutomaticPictureInPicture(false, tabID: tabID)
      return
    }
    runtime.setAutoPictureInPictureAllowed(false, tabID: tabID.uuidString)
  }

  func applyAutomaticPictureInPicture(site: String, profileID: UUID) {
    guard !isClosed, let store else { return }
    for tabID in liveTabs where store.session.profileID(forTabID: tabID) == profileID {
      guard let url = store.session.page(forTabID: tabID)?.tab.url,
        SiteSettingKey.site(for: url) == site
      else { continue }
      if mediaImplementation == .shaar {
        updateShaarAutomaticPictureInPicture(
          store.automaticPictureInPictureAllowed(for: url, profileID: profileID), tabID: tabID)
        continue
      }
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

  // BEGIN media
  private func performShaarMedia(_ command: MediaCommand, tabID: UUID) -> Bool {
    guard let adapter = shaarMediaAdapter, let scope = shaarMediaScope(for: tabID) else {
      return false
    }
    let mapped: (ShaarMediaCommand, Double?)
    switch command {
    case .perform(let action, let seconds):
      switch action {
      case .play: mapped = (.play, nil)
      case .pause: mapped = (.pause, nil)
      case .previousTrack: mapped = (.previousTrack, nil)
      case .nextTrack: mapped = (.nextTrack, nil)
      case .seekBackward: mapped = (.seekBackward, nil)
      case .seekForward: mapped = (.seekForward, nil)
      case .seekTo: mapped = (.seekTo, seconds)
      }
    case .setMuted(let muted): mapped = (.setTabMuted, muted ? 1 : 0)
    case .setVolume:
      // Chromium's public MediaSession API has no page-element volume operation.
      return false
    }
    Task { @MainActor [weak self] in
      do {
        try await adapter.control(mapped.0, scope: scope, value: mapped.1)
        let state = try await adapter.state(scope: scope)
        self?.applyShaarMediaState(state, to: tabID)
      } catch {
        // A rejected engine command does not become a success-shaped model update.
      }
    }
    return true
  }

  private func performShaarPictureInPicture(
    _ command: PictureInPictureControls.Command, tabID: UUID
  ) {
    guard let adapter = shaarMediaAdapter, let scope = shaarMediaScope(for: tabID) else { return }
    Task { @MainActor in
      do {
        switch command {
        case .play: try await adapter.control(.pipPlay, scope: scope)
        case .pause: try await adapter.control(.pipPause, scope: scope)
        case .skip(let seconds): try await adapter.control(.pipSkip, scope: scope, value: seconds)
        case .close, .backToTab: try await adapter.exitPictureInPicture(scope: scope)
        }
        if case .backToTab = command { self.showRequestedTab(tabID.uuidString) }
      } catch {
        return
      }
    }
  }

  private func updateShaarAutomaticPictureInPicture(_ allowed: Bool, tabID: UUID) {
    guard let adapter = shaarMediaAdapter, let scope = shaarMediaScope(for: tabID) else { return }
    Task { @MainActor in
      try? await adapter.setAutoPictureInPicture(allowed, scope: scope)
    }
  }

  func receiveShaarMediaEvent(_ event: ShaarCopiedEvent) {
    guard mediaImplementation == .shaar, let adapter = shaarMediaAdapter,
      let tabString = String(data: event.tabID, encoding: .utf8),
      let tabID = UUID(uuidString: tabString), ownedLiveTab(tabString) == tabID,
      let scope = shaarMediaScope(for: tabID),
      let change = try? adapter.decodeEvent(event, scope: scope)
    else { return }
    switch change {
    case .stateChanged(let state): applyShaarMediaState(state, to: tabID)
    case .pictureInPictureChanged(let state):
      receivePictureInPicture(tabString, active: state == "inPictureInPicture")
    case .captureChanged: break
    }
  }

  private func applyShaarMediaState(_ state: ShaarMediaState, to tabID: UUID) {
    let actions = Set(
      state.supportedActions.compactMap { raw -> MediaSessionAction? in
        switch raw {
        case 0: .play
        case 1: .pause
        case 2: .previousTrack
        case 3: .nextTrack
        case 4: .seekBackward
        case 5: .seekForward
        case 6: .seekTo
        default: nil
        }
      })
    let pictureInPicture: PictureInPictureVideo? =
      state.pipVideoState == "inPictureInPicture"
      ? .init(isPlaying: state.playbackState == .playing, isLive: false) : nil
    let model = MediaSessionState(
      playbackState: MediaPlaybackState(rawValue: state.playbackState.rawValue) ?? .none,
      title: state.title, artist: state.artist, album: state.album,
      artwork: state.artwork.flatMap { URL(string: $0) }, actions: actions,
      hasVideo: state.hasVideo, canSeek: state.canSeek, muted: state.tabMuted,
      // Do not auto-open a PiP window when the native layer cannot report page silence.
      silent: state.silent ?? true, pictureInPicture: pictureInPicture,
      volume: state.pageVolume)
    store?.media.update(tabID, state: model)
    if pictureInPictureControls.tabID == tabID {
      pictureInPictureControls.update(pictureInPicture)
    }
  }

  private func shaarMediaScope(for tabID: UUID) -> ShaarMediaScope? {
    guard ownedLiveTab(tabID.uuidString) == tabID,
      let expectedProfileID = store?.session.profileID(forTabID: tabID)?.uuidString,
      let scope = shaarMediaScopeForTab?(tabID),
      scope.profileID == expectedProfileID, scope.tabID == tabID.uuidString
    else { return nil }
    return scope
  }
  // END media
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
