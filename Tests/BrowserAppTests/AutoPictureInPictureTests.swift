// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class AutoPictureInPictureTests: XCTestCase {
  private var entered: [UUID] = []
  private var exited: [UUID] = []
  private var chromiumPages: Set<UUID> = []
  private let video = MediaSessionState(
    playbackState: .playing, actions: [.play, .pause], hasVideo: true)

  private func controller() -> AutoPictureInPicture {
    AutoPictureInPicture(
      engine: .init(
        enter: { [unowned self] in entered.append($0) },
        exit: { [unowned self] in exited.append($0) },
        handlesAutomatically: { [unowned self] in chromiumPages.contains($0) }))
  }

  func testLeavingPlayingVideoOpensAndReturningCloses() {
    let pip = controller()
    let page = UUID()
    let other = UUID()
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    pip.visiblePagesChanged(to: [other], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(entered, [page])
    pip.pictureInPictureChanged(page, active: true)
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(exited, [page])
  }

  func testOnlyAudiblePlayingVideoQualifies() {
    var paused = video
    paused.playbackState = .paused
    var audio = video
    audio.hasVideo = false
    var silent = video
    silent.silent = true
    for state in [paused, audio, silent] {
      let pip = controller()
      let page = UUID()
      pip.visiblePagesChanged(to: [page], sessions: [page: state], allowed: { _ in true })
      pip.visiblePagesChanged(to: [], sessions: [page: state], allowed: { _ in true })
    }
    XCTAssertEqual(entered, [])
  }

  func testSiteSettingOffKeepsPageInTab() {
    let pip = controller()
    let page = UUID()
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in false })
    pip.visiblePagesChanged(to: [], sessions: [page: video], allowed: { _ in false })
    XCTAssertEqual(entered, [])
  }

  func testChromiumOwnAutomaticWindowIsNotRequestedTwice() {
    let pip = controller()
    let page = UUID()
    chromiumPages = [page]
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    pip.visiblePagesChanged(to: [], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(entered, [])
    pip.pictureInPictureChanged(page, active: true)
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(exited, [page], "returning still closes the automatic window")
  }

  func testManualWindowStaysWhenReturning() {
    let pip = controller()
    let page = UUID()
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    pip.pictureInPictureChanged(page, active: true)
    pip.visiblePagesChanged(to: [], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(entered, [], "already open")
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(exited, [], "the user opened it; Shaar leaves it")
  }

  func testWindowOpeningAfterReturnCloses() {
    let pip = controller()
    let page = UUID()
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    pip.visiblePagesChanged(to: [], sessions: [page: video], allowed: { _ in true })
    pip.visiblePagesChanged(to: [page], sessions: [page: video], allowed: { _ in true })
    XCTAssertEqual(exited, [], "nothing open yet")
    pip.pictureInPictureChanged(page, active: true)
    XCTAssertEqual(exited, [page])
  }

  func testStoreSettingIsPerSiteAndProfile() throws {
    var session = BrowserSession.fresh()
    let video = try XCTUnwrap(session.open(URL(string: "https://www.youtube.com/watch?v=1")!))
    let store = BrowserStore(session: session)
    let profile = store.session.selectedSpace.profileID
    var changes: [(String, UUID)] = []
    store.onAutomaticPictureInPictureChanged = { changes.append(($0, $1)) }
    let watch = URL(string: "https://www.youtube.com/watch?v=2")!
    XCTAssertTrue(store.automaticPictureInPictureAllowed(for: watch, profileID: profile))
    XCTAssertTrue(store.automaticPictureInPictureAllowed(forTab: video))

    store.setAutomaticPictureInPicture(false, for: watch, profileID: profile)
    XCTAssertFalse(store.automaticPictureInPictureAllowed(forTab: video))
    XCTAssertTrue(
      store.automaticPictureInPictureAllowed(
        for: URL(string: "https://vimeo.com")!, profileID: profile))
    XCTAssertTrue(store.automaticPictureInPictureAllowed(for: watch, profileID: UUID()))
    XCTAssertEqual(changes.map(\.0), ["www.youtube.com"])

    store.setAutomaticPictureInPicture(true, for: watch, profileID: profile)
    XCTAssertTrue(store.automaticPictureInPictureAllowed(forTab: video))
  }

  func testSiteSettingPersists() {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString)/preferences.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let profile = UUID()
    BrowserPreferencesStore(fileURL: file)
      .setAutomaticPictureInPicture(false, on: "www.youtube.com", for: profile)
    let reloaded = BrowserPreferencesStore(fileURL: file)
    XCTAssertFalse(reloaded.allowsAutomaticPictureInPicture(on: "www.youtube.com", for: profile))
    XCTAssertTrue(reloaded.allowsAutomaticPictureInPicture(on: "vimeo.com", for: profile))
    XCTAssertNil(reloaded.storageNotice)
  }
}
