// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum MediaPlaybackState: String, Sendable {
  case none, paused, playing
}

/// Media Session actions a page can support. Raw values are the Media Session action names.
enum MediaSessionAction: String, CaseIterable, Sendable {
  case play, pause
  case previousTrack = "previoustrack"
  case nextTrack = "nexttrack"
  case seekBackward = "seekbackward"
  case seekForward = "seekforward"
  case seekTo = "seekto"
}

/// The video in Chromium's picture-in-picture window.
struct PictureInPictureVideo: Equatable, Sendable {
  var isPlaying: Bool
  /// A live stream has no duration to skip within.
  var isLive: Bool

  init(isPlaying: Bool, isLive: Bool) {
    self.isPlaying = isPlaying
    self.isLive = isLive
  }

  init?(payload: Any?) {
    guard let payload = payload as? [String: Any] else { return nil }
    self.init(
      isPlaying: payload["playing"] as? Bool ?? false, isLive: payload["live"] as? Bool ?? false)
  }
}

/// One tab's playback as reported by the engine bridge.
struct MediaSessionState: Equatable, Sendable {
  var playbackState: MediaPlaybackState
  var title: String
  var artist: String
  var album: String
  var artwork: URL?
  var actions: Set<MediaSessionAction>
  var hasVideo: Bool
  var canSeek: Bool
  var muted: Bool
  /// The playing element is muted or at zero volume in the page.
  var silent: Bool
  /// Nil when the reporting frame has no media element whose volume can be changed.
  var volume: Double?
  var pictureInPicture: PictureInPictureVideo?

  init(
    playbackState: MediaPlaybackState, title: String = "", artist: String = "",
    album: String = "", artwork: URL? = nil, actions: Set<MediaSessionAction> = [],
    hasVideo: Bool = false, canSeek: Bool = false, muted: Bool = false, silent: Bool = false,
    pictureInPicture: PictureInPictureVideo? = nil, volume: Double? = nil
  ) {
    self.playbackState = playbackState
    self.title = title
    self.artist = artist
    self.album = album
    self.artwork = artwork
    self.actions = actions
    self.hasVideo = hasVideo
    self.canSeek = canSeek
    self.muted = muted
    self.silent = silent
    self.pictureInPicture = pictureInPicture
    self.volume = volume.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
  }

  /// Parses the bridge payload. Unknown action names are ignored; a missing or unknown
  /// playback state rejects the payload.
  init?(payload: [String: Any]) {
    guard let raw = payload["playbackState"] as? String,
      let playbackState = MediaPlaybackState(rawValue: raw)
    else { return nil }
    let names = payload["actions"] as? [String] ?? []
    self.init(
      playbackState: playbackState,
      title: payload["title"] as? String ?? "",
      artist: payload["artist"] as? String ?? "",
      album: payload["album"] as? String ?? "",
      artwork: Self.artworkURL(payload["artwork"]),
      actions: Set(names.compactMap(MediaSessionAction.init(rawValue:))),
      hasVideo: payload["hasVideo"] as? Bool ?? false,
      canSeek: payload["canSeek"] as? Bool ?? false,
      muted: payload["muted"] as? Bool ?? false,
      silent: payload["silent"] as? Bool ?? false,
      pictureInPicture: PictureInPictureVideo(payload: payload["pictureInPicture"]),
      volume: Self.parseVolume(payload["volume"]))
  }

  var isPlaying: Bool { playbackState == .playing }

  func supports(_ action: MediaSessionAction) -> Bool { actions.contains(action) }

  /// Pause while playing, play otherwise; nil when the page cannot do that.
  var playPauseAction: MediaSessionAction? {
    let action: MediaSessionAction = isPlaying ? .pause : .play
    return supports(action) ? action : nil
  }

  private static func artworkURL(_ value: Any?) -> URL? {
    guard let text = value as? String, let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased())
    else { return nil }
    return url
  }

  private static func parseVolume(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return number.doubleValue
  }
}

/// A user command for one tab's media.
enum MediaCommand: Equatable, Sendable {
  /// `seconds` is the offset for seeking backward or forward (zero uses the page's default)
  /// and the position for seeking to.
  case perform(MediaSessionAction, seconds: TimeInterval = 0)
  case setMuted(Bool)
  case setVolume(Double)
}
