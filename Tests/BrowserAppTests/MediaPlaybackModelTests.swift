// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class MediaPlaybackModelTests: XCTestCase {
  private let playing = MediaSessionState(
    playbackState: .playing, title: "Song", artist: "Artist",
    actions: [.play, .pause, .previousTrack, .nextTrack])

  func testPayloadParsesKnownFieldsAndDropsUnknownActions() throws {
    let state = try XCTUnwrap(
      MediaSessionState(payload: [
        "playbackState": "playing", "title": "Song", "artist": "Artist", "album": "Album",
        "artwork": "https://music.example/cover.png",
        "actions": ["play", "pause", "nexttrack", "skipad"],
        "hasVideo": true, "canSeek": true, "muted": true, "silent": true,
        "pictureInPicture": ["playing": false, "live": true],
      ]))
    XCTAssertEqual(state.playbackState, .playing)
    XCTAssertEqual(state.title, "Song")
    XCTAssertEqual(state.artist, "Artist")
    XCTAssertEqual(state.album, "Album")
    XCTAssertEqual(state.artwork, URL(string: "https://music.example/cover.png"))
    XCTAssertEqual(state.actions, [.play, .pause, .nextTrack])
    XCTAssertTrue(state.hasVideo)
    XCTAssertTrue(state.canSeek)
    XCTAssertTrue(state.muted)
    XCTAssertTrue(state.silent)
    XCTAssertEqual(state.pictureInPicture, PictureInPictureVideo(isPlaying: false, isLive: true))
  }

  func testPayloadRejectsUnknownPlaybackStateAndNonWebArtwork() {
    XCTAssertNil(MediaSessionState(payload: ["playbackState": "buffering"]))
    XCTAssertNil(MediaSessionState(payload: ["title": "No state"]))
    let state = MediaSessionState(payload: [
      "playbackState": "paused", "artwork": "javascript:alert(1)",
    ])
    XCTAssertNil(state?.artwork)
    XCTAssertEqual(state?.actions, [])
    XCTAssertNil(state?.pictureInPicture, "no video in picture-in-picture")
  }

  func testPlayPauseFollowsPlaybackAndSupport() {
    XCTAssertEqual(playing.playPauseAction, .pause)
    var paused = playing
    paused.playbackState = .paused
    XCTAssertEqual(paused.playPauseAction, .play)
    paused.actions = [.pause]
    XCTAssertNil(paused.playPauseAction)
  }

  func testVolumeAcceptsOnlyFiniteNumbersInRange() throws {
    for volume in [0.0, 0.25, 1.0] {
      let state = MediaSessionState(payload: ["playbackState": "playing", "volume": volume])
      XCTAssertEqual(state?.volume, volume)
    }
    for volume: Any in [NSNull(), true, "0.5", -0.1, 1.1, Double.nan, Double.infinity] {
      let state = MediaSessionState(payload: ["playbackState": "playing", "volume": volume])
      XCTAssertNil(try XCTUnwrap(state).volume)
    }
    XCTAssertNil(playing.volume, "metadata alone does not imply a controllable element")
  }

  func testPlayerShowsHiddenPlayingTabOnly() {
    let model = MediaPlaybackModel()
    let tab = UUID()
    model.update(tab, state: playing)
    XCTAssertEqual(model.miniPlayerTabID(hiding: []), tab)
    XCTAssertNil(model.miniPlayerTabID(hiding: [tab]), "the selected tab plays on screen")
  }

  func testTabThatNeverPlayedStaysOut() {
    let model = MediaPlaybackModel()
    model.update(UUID(), state: MediaSessionState(playbackState: .paused, actions: [.play]))
    XCTAssertNil(model.miniPlayerTabID(hiding: []))
  }

  func testPausedTabRemainsSoItCanResume() {
    let model = MediaPlaybackModel()
    let tab = UUID()
    model.update(tab, state: playing)
    var paused = playing
    paused.playbackState = .paused
    model.update(tab, state: paused)
    XCTAssertEqual(model.miniPlayerTabID(hiding: []), tab)
  }

  func testStoppedOrClosedPlaybackHidesPlayer() {
    let model = MediaPlaybackModel()
    let stopped = UUID()
    let closed = UUID()
    model.update(stopped, state: playing)
    model.update(closed, state: playing)
    model.update(stopped, state: MediaSessionState(playbackState: .none))
    model.update(closed, state: nil)
    XCTAssertNil(model.miniPlayerTabID(hiding: []))
    XCTAssertTrue(model.sessions.isEmpty)
  }

  func testPlayingTabWinsThenMostRecentStart() {
    let model = MediaPlaybackModel()
    let first = UUID()
    let second = UUID()
    var paused = playing
    paused.playbackState = .paused
    model.update(first, state: playing)
    model.update(second, state: playing)
    XCTAssertEqual(model.miniPlayerTabID(hiding: []), second)
    model.update(second, state: paused)
    XCTAssertEqual(model.miniPlayerTabID(hiding: []), first, "playing beats paused")
    model.update(first, state: paused)
    XCTAssertEqual(model.miniPlayerTabID(hiding: []), second, "then the latest start")
  }

  func testStoreHidesPlayerForVisiblePageAndSelectsPlayingTab() throws {
    var session = BrowserSession.fresh()
    let music = try XCTUnwrap(session.open(URL(string: "https://music.example")!))
    let other = try XCTUnwrap(session.open(URL(string: "https://other.example")!))
    let store = BrowserStore(session: session)
    store.media.update(music, state: playing)
    XCTAssertEqual(store.session.selectedPage?.tab.id, other)
    XCTAssertEqual(store.miniPlayerItem?.tabID, music)

    store.selectPage(music)
    XCTAssertEqual(store.session.selectedPage?.tab.id, music)
    XCTAssertNil(store.miniPlayerItem, "the player hides while its tab is selected")
  }

  func testStoreSelectsPlayingTabInAnotherSpace() throws {
    let session = BrowserSession.fresh()
    let store = BrowserStore(session: session)
    let firstSpace = store.session.selectedSpaceID
    let music = try XCTUnwrap(store.session.open(URL(string: "https://music.example")!))
    XCTAssertTrue(store.createSpace(name: "Work", sharingProfile: nil, tint: .forest))
    XCTAssertNotEqual(store.session.selectedSpaceID, firstSpace)
    store.media.update(music, state: playing)
    XCTAssertEqual(store.miniPlayerItem?.tabID, music)

    store.selectPage(music)
    XCTAssertEqual(store.session.selectedSpaceID, firstSpace)
    XCTAssertEqual(store.session.selectedPage?.tab.id, music)
  }

  func testCommandsRouteToTheEngine() {
    let store = BrowserStore(session: .fresh())
    let tab = UUID()
    var received: [(UUID, MediaCommand)] = []
    XCTAssertFalse(store.performMedia(.perform(.play), tabID: tab), "no engine attached")
    store.onMediaCommand = { id, command in
      received.append((id, command))
      return true
    }
    XCTAssertTrue(store.performMedia(.perform(.nextTrack), tabID: tab))
    XCTAssertTrue(store.performMedia(.setMuted(true), tabID: tab))
    XCTAssertTrue(store.performMedia(.setVolume(0.35), tabID: tab))
    XCTAssertEqual(received.map(\.0), [tab, tab, tab])
    XCTAssertEqual(received.map(\.1), [.perform(.nextTrack), .setMuted(true), .setVolume(0.35)])
  }
}
