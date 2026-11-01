// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Plays a silent canvas video with an authored Media Session on the loopback fixture and
/// drives it through the bridge and the sidebar player model. Audio is muted by the engine.
@MainActor
final class MediaSessionProbe {
  private static let spaceName = "Media session probe"
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    fixture: URL, phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    let home = store.session.spaces[0]
    let (space, media) = try await mediaTab(sharingProfileOf: home)
    try await startPlayback(media)
    let state = try await waitForSession(media) { $0.isPlaying }
    try expect(
      state.title == "Fixture Song" && state.artist == "Fixture Artist"
        && state.album == "Fixture Album",
      "Media Session metadata reaches the app")
    try expect(
      state.artwork?.path == "/favicon-initial.png", "artwork resolves to an absolute web URL")
    try expect(
      state.actions == [.play, .pause, .previousTrack, .nextTrack],
      "supported actions are the page's handlers; a live stream offers no seeking")
    try expect(state.hasVideo && !state.canSeek, "video without a seekable duration")
    try expect(store.miniPlayerItem == nil, "no player while the playing tab is on screen")

    store.perform(.space(home.id))
    try await waitUntil("player for a hidden playing tab") {
      self.store.miniPlayerItem?.tabID == media
    }
    try await capture(name: "\(phase)-media-player.png")
    try await expectHandled(.nextTrack, "nexttrack", in: media)
    try await expectHandled(.previousTrack, "previoustrack", in: media)
    try await expectHandled(.pause, "pause", in: media)
    _ = try await waitForSession(media) { $0.playbackState == .paused }
    try expect(store.miniPlayerItem?.tabID == media, "a paused tab keeps its player to resume")
    try await expectHandled(.play, "play", in: media)
    _ = try await waitForSession(media) { $0.isPlaying }
    try expect(
      !store.performMedia(.perform(.seekTo, seconds: 5), tabID: media),
      "an unsupported action is not sent")

    try expect(store.performMedia(.setMuted(true), tabID: media), "mute is delivered")
    _ = try await waitForSession(media) { $0.muted }
    try expect(store.performMedia(.setMuted(false), tabID: media), "unmute is delivered")
    _ = try await waitForSession(media) { !$0.muted }
    checks.append("mute toggles the engine's tab audio")

    store.selectPage(media)
    try expect(
      store.session.selectedSpaceID == space && store.session.selectedPage?.tab.id == media,
      "the player's site icon returns to the playing tab's Space")
    try expect(store.miniPlayerItem == nil, "the player hides when its tab is selected")
    try await checkAutomaticPictureInPicture(home: home, space: space, media: media)

    _ = await evaluate(media, "(()=>{location.reload();return {};})()")
    try await waitUntil("a new document clears the old session") {
      self.store.media.sessions[media] == nil
    }
    store.perform(.space(home.id))
    return checks
  }

  /// The probe's own Space shares the first profile so no extra profile loads.
  private func mediaTab(sharingProfileOf home: BrowserSpace) async throws -> (UUID, UUID) {
    if store.session.spaces.first(where: { $0.name == Self.spaceName }) == nil {
      guard
        store.createSpace(name: Self.spaceName, sharingProfile: home.profileID, tint: .ocean)
      else { throw MediaSessionProbeFailure("Could not create the media Space.") }
      store.perform(.open(fixture))
      store.perform(.open(mediaURL))
    }
    guard let space = store.session.spaces.first(where: { $0.name == Self.spaceName }),
      let tab = space.tabs.first(where: { $0.url.path == "/media" })
    else { throw MediaSessionProbeFailure("The media Space has no media tab.") }
    store.perform(.tab(space: space.id, tab: tab.id))
    try await waitUntil("media fixture loads") {
      await self.evaluate(tab.id, "({ready:document.documentElement.dataset.arcusisFixture})")?[
        "ready"] as? String == "media"
    }
    return (space.id, tab.id)
  }

  /// Chromium's overlay window is kept transparent and click-through by the engine's
  /// background mode, which the fixture sets; nothing appears on screen.
  private func checkAutomaticPictureInPicture(home: BrowserSpace, space: UUID, media: UUID)
    async throws
  {
    guard
      let other = store.session.spaces.first(where: { $0.id == space })?.tabs
        .first(where: { $0.url.path != "/media" })?.id
    else { throw MediaSessionProbeFailure("The media Space has no second tab.") }
    // The mini player steps hid this tab; that window must close before measuring.
    try await waitForPictureInPicture(media, open: false)
    store.perform(.tab(space: space, tab: other))
    try await waitForPictureInPicture(media, open: true)
    checks.append("switching tabs away from a playing video opens Chromium's video window")
    try await checkLiveVideoControls(media)
    try await press(.backToTab)
    try await waitForPictureInPicture(media, open: false)
    try expect(
      store.session.selectedPage?.tab.id == media && !engine.pictureInPictureControls.isAttached,
      "Back to Tab returns to the tab and closes the window")

    store.perform(.space(home.id))
    try await waitForPictureInPicture(media, open: true)
    checks.append("switching Space away from a playing video opens the window")
    store.perform(.tab(space: space, tab: media))
    try await waitForPictureInPicture(media, open: false)
    checks.append("returning to the Space closes the window")

    store.setAutomaticPictureInPicture(false, for: mediaURL, profileID: home.profileID)
    store.perform(.tab(space: space, tab: other))
    try await Task.sleep(for: .milliseconds(1500))
    try expect(
      !(await pictureInPictureOpen(media)), "a site turned off stays in its tab when left")
    store.perform(.tab(space: space, tab: media))
    store.setAutomaticPictureInPicture(true, for: mediaURL, profileID: home.profileID)
    _ = try await waitForSession(media) { $0.isPlaying }
    try await checkSkipControls(media)
  }

  /// Shaar's controls over Chromium's window, on the canvas stream, which is live.
  private func checkLiveVideoControls(_ media: UUID) async throws {
    let controls = engine.pictureInPictureControls
    try await waitUntil("controls attach to Chromium's window") {
      controls.tabID == media && controls.panel?.parent === controls.videoWindow
        && controls.videoWindow != nil
    }
    guard let window = controls.videoWindow, let panel = controls.panel else {
      throw MediaSessionProbeFailure("The controls lost Chromium's window.")
    }
    try expect(panel.frame == window.frame, "the controls cover Chromium's video window")
    try expect(
      panel.alphaValue == 0 && panel.ignoresMouseEvents,
      "the controls stay invisible while the engine hides its window")
    try await waitUntil("live video presentation") { controls.view.presentation.isLive }
    try expect(
      controls.view.availableControls == [.backToTab, .minimize, .close, .playPause],
      "a live stream offers close, minimize, back to tab and play/pause, without skipping")

    try await press(.playPause)
    try await waitUntil("play/pause pauses the video") {
      await self.videoPaused("video", in: media) == true && !controls.view.presentation.isPlaying
    }
    try await press(.playPause)
    try await waitUntil("play/pause resumes the video") {
      await self.videoPaused("video", in: media) == false && controls.view.presentation.isPlaying
    }
    checks.append("play/pause pauses and resumes the video in the window")

    try await checkMinimize(window, controls: controls, tab: media)
    try await checkMoveAndResize(window, panel: panel, controls: controls)
  }

  private func checkMinimize(
    _ window: NSWindow, controls: PictureInPictureControls, tab: UUID
  ) async throws {
    let original = window.frame
    guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else {
      throw MediaSessionProbeFailure("Chromium's window has no screen.")
    }
    try await press(.minimize)
    let tucked = PictureInPictureGeometry.tucked(original, in: screen)
    try await waitUntil("minimize tucks the window") { window.frame == tucked }
    try await Task.sleep(for: .milliseconds(300))
    try expect(
      window.frame.intersection(screen).width == PictureInPictureGeometry.tuckedWidth,
      "minimize tucks the window to the screen edge",
      detail: "frame \(window.frame), screen \(screen), original \(original)")
    try expect(
      controls.view.availableControls == [.restore], "a tucked window offers only restore",
      detail: "\(controls.view.availableControls)")
    let paused = await videoPaused("video", in: tab)
    try expect(
      paused == false && window.isVisible,
      "playback continues while the window is tucked")
    try await press(.restore)
    try await waitUntil("restore returns the window") { window.frame == original }
    checks.append("restore returns the window to its place with its controls")
  }

  private func checkMoveAndResize(
    _ window: NSWindow, panel: NSPanel, controls: PictureInPictureControls
  ) async throws {
    let original = window.frame
    drag(
      controls.view, panel: panel, from: CGPoint(x: original.midX, y: original.midY),
      by: CGSize(width: -40, height: -40))
    let moved = original.offsetBy(dx: -40, dy: -40)
    try await waitUntil("dragging moves the window") {
      window.frame == moved && panel.frame == moved
    }
    checks.append("dragging the video moves the window and its controls")

    drag(
      controls.view, panel: panel, from: CGPoint(x: moved.maxX - 2, y: moved.minY + 2),
      by: CGSize(width: 64, height: -64))
    try await waitUntil("dragging the corner resizes the window") {
      window.frame.width > moved.width && panel.frame == window.frame
    }
    let aspect = window.frame.width / window.frame.height
    try expect(
      abs(aspect - moved.width / moved.height) < 0.02 && abs(window.frame.maxY - moved.maxY) < 1
        && abs(window.frame.minX - moved.minX) < 1,
      "dragging a corner resizes the window, keeping its shape and opposite corner")
    window.setFrame(original, display: true)
  }

  /// A clip with a duration in a window opened from the visible tab.
  private func checkSkipControls(_ media: UUID) async throws {
    let controls = engine.pictureInPictureControls
    try await waitUntil("the clip loads") {
      await self.evaluate(media, "({ready:document.getElementById('clip').readyState>1})")?[
        "ready"] as? Bool == true
    }
    let opened = await evaluate(
      media,
      "(()=>{const c=document.getElementById('clip');c.currentTime=5;"
        + "c.play().then(()=>c.requestPictureInPicture());return {opened:true};})()",
      userGesture: true)
    try expect(opened?["opened"] as? Bool == true, "the clip opens picture-in-picture")
    try await waitForPictureInPicture(media, open: true)
    try await waitUntil("controls for the clip") {
      controls.tabID == media && !controls.view.presentation.isLive
    }
    try expect(
      controls.view.availableControls
        == [.backToTab, .minimize, .close, .skipBack, .playPause, .skipForward],
      "a video with a duration offers all six controls")

    try await press(.playPause)
    try await waitUntil("the clip pauses") { await self.videoPaused("clip", in: media) == true }
    let start = try await clipTime(media)
    try await press(.skipForward)
    try await waitUntil("skip forward") { await self.clipTime(media, near: start + 10) }
    checks.append("skip forward moves the video 10 seconds ahead")
    try await press(.skipBack)
    try await waitUntil("skip back") { await self.clipTime(media, near: start) }
    checks.append("skip back moves the video 10 seconds back")
    try await press(.playPause)
    try await waitUntil("the clip resumes") { await self.videoPaused("clip", in: media) == false }

    try await press(.close)
    try await waitForPictureInPicture(media, open: false)
    try await Task.sleep(for: .milliseconds(300))
    let clipPaused = await videoPaused("clip", in: media)
    try expect(
      !controls.isAttached && clipPaused == false,
      "close removes the window and its controls and keeps the video playing in its tab")
    _ = await evaluate(media, "(()=>{document.getElementById('clip').pause();return {};})()")
  }

  private func press(_ control: PictureInPictureControlsView.Control) async throws {
    guard let button = engine.pictureInPictureControls.view.button(control), !button.isHidden
    else { throw MediaSessionProbeFailure("No \(control.rawValue) button to press.") }
    button.performClick(nil)
    try await Task.sleep(for: .milliseconds(50))
  }

  /// Sends a pointer drag to the controls without moving the real pointer.
  private func drag(
    _ view: PictureInPictureControlsView, panel: NSPanel, from start: CGPoint, by offset: CGSize
  ) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, panel: panel))
    let end = CGPoint(x: start.x + offset.width, y: start.y + offset.height)
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, panel: panel))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, panel: panel))
  }

  private func mouseEvent(_ type: NSEvent.EventType, at screenPoint: CGPoint, panel: NSPanel)
    -> NSEvent
  {
    let point = CGPoint(
      x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
    return NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
      pressure: 1)!
  }

  private func videoPaused(_ id: String, in tab: UUID) async -> Bool? {
    await evaluate(tab, "({paused:document.getElementById('\(id)').paused})")?["paused"]
      as? Bool
  }

  private func clipTime(_ tab: UUID, near expected: Double) async -> Bool {
    guard let time = try? await clipTime(tab) else { return false }
    return abs(time - expected) < 0.5
  }

  private func clipTime(_ tab: UUID) async throws -> Double {
    guard
      let time = await evaluate(tab, "({time:document.getElementById('clip').currentTime})")?[
        "time"] as? Double
    else { throw MediaSessionProbeFailure("The clip has no position.") }
    return time
  }

  private func waitForPictureInPicture(_ tab: UUID, open: Bool) async throws {
    try await waitUntil("picture-in-picture \(open ? "opens" : "closes")") {
      await self.pictureInPictureOpen(tab) == open
        && self.engine.autoPictureInPicture.openPages.contains(tab) == open
    }
  }

  private func pictureInPictureOpen(_ tab: UUID) async -> Bool {
    await evaluate(tab, "({open:document.pictureInPictureElement!==null})")?["open"] as? Bool
      == true
  }

  private var mediaURL: URL {
    var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    components.path = "/media"
    return components.url!
  }

  private func startPlayback(_ tab: UUID) async throws {
    let started = await evaluate(
      tab, "(()=>{document.getElementById('video').play();return {started:true};})()",
      userGesture: true)
    try expect(started?["started"] as? Bool == true, "fixture video starts on a user gesture")
  }

  private func expectHandled(_ action: MediaSessionAction, _ name: String, in media: UUID)
    async throws
  {
    try expect(
      store.performMedia(.perform(action), tabID: media), "\(name) is sent to the page")
    try await waitUntil("\(name) reaches the page's handler") {
      let log = await self.evaluate(media, "({log:window.arcusisMediaLog})")?["log"] as? [String]
      return log?.last == name
    }
    checks.append("\(name) runs the page's Media Session handler")
  }

  private func waitForSession(
    _ tab: UUID, _ predicate: @escaping (MediaSessionState) -> Bool
  ) async throws -> MediaSessionState {
    try await waitUntil("media session state") {
      self.store.media.sessions[tab].map(predicate) == true
    }
    return store.media.sessions[tab]!
  }

  private func waitUntil(_ name: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<100 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MediaSessionProbeFailure("Timed out: \(name).")
  }

  private func evaluate(_ tab: UUID, _ expression: String, userGesture: Bool = false) async
    -> [String: Any]?
  {
    let json: String? = await withCheckedContinuation { continuation in
      if userGesture {
        runtime.evaluateProbeUserGesture(inTabID: tab.uuidString, script: expression) {
          continuation.resume(returning: $0)
        }
      } else {
        runtime.evaluate(inTabID: tab.uuidString, script: expression) {
          continuation.resume(returning: $0)
        }
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func capture(name: String) async throws {
    let size = NSSize(width: 200, height: 520)
    let host = NSHostingView(
      rootView: BrowserSidebar(store: store).frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw MediaSessionProbeFailure("Could not render the sidebar player.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw MediaSessionProbeFailure("Could not encode the sidebar player.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(
    _ condition: Bool, _ name: String, detail: @autoclosure () -> String = ""
  ) throws {
    guard condition else {
      let suffix = detail()
      throw MediaSessionProbeFailure(suffix.isEmpty ? name : "\(name): \(suffix)")
    }
    checks.append(name)
  }
}

private struct MediaSessionProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
