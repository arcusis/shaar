// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI
import Testing
import XCTest

@testable import ArcusisBrowser

@Suite @MainActor
struct MiniBrowserTests {
  @Test func externalURLRoutingHonorsPreferenceAndRejectsOtherSchemes() {
    let url = URL(string: "https://example.com")!
    #expect(MiniLinkRoute.route(url, inMainWindow: false) == .mini(url))
    #expect(MiniLinkRoute.route(url, inMainWindow: true) == .main(url))
    #expect(MiniLinkRoute.route(URL(string: "file:///tmp/a")!, inMainWindow: false) == nil)
  }

  @Test func moveAndArchivePreserveSpaceAndProfile() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpace
    let tab = BrowserTab(url: URL(string: "https://example.com/path")!, title: "Example")
    #expect(store.receiveMiniTab(tab, in: space.id, profileID: UUID(), archive: false) == false)
    #expect(store.receiveMiniTab(tab, in: space.id, profileID: space.profileID, archive: false))
    #expect(store.session.selectedSpace.selectedTab?.title == "Example")
    #expect(store.receiveMiniTab(tab, in: space.id, profileID: space.profileID, archive: true))
    #expect(store.session.recentlyClosedTabs(in: space.id).first?.tab.url == tab.url)
  }

  @Test func archivingMiniTabDoesNotChangeMainWindowSelection() throws {
    var session = BrowserSession.fresh()
    let first = session.open(URL(string: "https://first.example")!)!
    _ = session.open(URL(string: "https://second.example")!)
    let spaceID = session.selectedSpaceID
    session.selectTab(first, in: spaceID)
    let store = BrowserStore(session: session)
    let miniTab = BrowserTab(url: URL(string: "https://mini.example")!)

    #expect(
      store.receiveMiniTab(
        miniTab, in: spaceID, profileID: session.selectedSpace.profileID, archive: true))
    #expect(store.session.selectedSpace.selectedTabID == first)
    #expect(store.session.recentlyClosedTabs(in: spaceID).first?.tab.url == miniTab.url)
  }

  @Test func archivingMiniTabKeepsSelectedFavorite() throws {
    var session = BrowserSession.fresh()
    let spaceID = session.selectedSpaceID
    let profileID = session.selectedSpace.profileID
    _ = session.open(URL(string: "https://ordinary.example")!)
    let favoriteID = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example")!)!
    let selected = session.selectFavorite(favoriteID, in: spaceID)
    #expect(selected)
    let store = BrowserStore(session: session)

    #expect(
      store.receiveMiniTab(
        BrowserTab(url: URL(string: "https://mini.example")!), in: spaceID,
        profileID: profileID, archive: true))
    #expect(store.session.selectedSpace.selectedFavoriteID == favoriteID)
  }

  @Test func failedMiniWindowCreationClosesNativeWindow() {
    let runtime = MiniWindowCreationRuntime()
    let target = BrowserStore()
    let targetWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.borderless],
      backing: .buffered, defer: false)
    targetWindow.isReleasedWhenClosed = false
    defer { targetWindow.close() }

    #expect(throws: (any Error).self) {
      try MiniBrowserController(
        events: BrowserRuntimeEvents(runtime: runtime), target: target,
        targetWindow: targetWindow, url: nil)
    }
    #expect(runtime.createdIDs.count == 1)
    #expect(runtime.closedIDs == runtime.createdIDs)
  }
}

private final class MiniWindowCreationRuntime: ARCChromiumRuntime {
  var createdIDs: [String] = []
  var closedIDs: [String] = []

  override func createWindowID(_ windowID: String) throws {
    createdIDs.append(windowID)
  }

  override func closeWindowID(_ windowID: String) -> Bool {
    closedIDs.append(windowID)
    return true
  }
}

@MainActor final class MiniBrowserVisualTests: XCTestCase {
  func testCapture() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let store = BrowserStore()
    let space = store.session.selectedSpace
    store.perform(.open(URL(string: "https://example.com")!))
    let view = MiniBrowserWindow(
      store: store, engine: nil, destinations: [space],
      destination: space.id, onNavigate: { _ in }, onDestination: { _ in }, onOpen: {})
    let host = NSHostingView(rootView: view.frame(width: 680, height: 520))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let _ = try VisualCapture.render(host, to: URL(fileURLWithPath: "/tmp/mini-browser.png"))
    window.close()
  }
}
