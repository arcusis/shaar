import AppKit
import BrowserCore
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
}

@MainActor final class MiniBrowserVisualTests: XCTestCase {
  func testCapture() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let store = BrowserStore()
    let space = store.session.selectedSpace
    store.perform(.open(URL(string: "https://example.com")!))
    let view = MiniBrowserWindow(store: store, engine: nil, destinations: [space],
      destination: space.id, onNavigate: { _ in }, onDestination: { _ in }, onOpen: {})
    let host = NSHostingView(rootView: view.frame(width: 680, height: 520))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/mini-browser.png"))
    window.close()
  }
}
