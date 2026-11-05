// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ChromiumPageContainerHandoffTests: XCTestCase {
  func testNativeActivationReturnsReparentedPageToLatestContainer() {
    let tab = UUID()
    let page = NSView()
    let browser = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [],
      backing: .buffered, defer: false)
    let foreign = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [],
      backing: .buffered, defer: false)
    browser.isReleasedWhenClosed = false
    foreign.isReleasedWhenClosed = false
    browser.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    foreign.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    defer {
      browser.close()
      foreign.close()
    }
    let old = ChromiumPageContainerView(frame: browser.contentView!.bounds)
    let latest = ChromiumPageContainerView(frame: browser.contentView!.bounds)
    browser.contentView?.addSubview(old)
    browser.contentView?.addSubview(latest)
    old.select(page, tabID: tab, liveTabs: [tab])
    latest.select(page, tabID: tab, liveTabs: [tab])
    foreign.contentView?.addSubview(page)
    XCTAssertTrue(page.window === foreign)

    XCTAssertTrue(
      ChromiumPageContainerView.restoreSelectedPage(page, tabID: tab, in: browser))
    XCTAssertTrue(page.superview === latest)
    XCTAssertTrue(page.window === browser)
  }

  func testOutgoingContainerHandsPageBackOnTeardown() {
    let tab = UUID()
    let page = NSView()
    let incoming = ChromiumPageContainerView()
    let outgoing = ChromiumPageContainerView()
    outgoing.select(page, tabID: tab, liveTabs: [tab])
    incoming.select(page, tabID: tab, liveTabs: [tab])
    // An animating, outgoing pane updates once more and takes the page back.
    outgoing.select(page, tabID: tab, liveTabs: [tab])
    XCTAssertTrue(page.superview === outgoing)
    outgoing.dismantle()
    XCTAssertTrue(page.superview === incoming)
    XCTAssertTrue(incoming.pageView === page)
  }

  func testFavoritingASplitTabKeepsTheRestOfTheSplit() throws {
    var session = BrowserSession.fresh()
    let ids = try (0..<3).map {
      try XCTUnwrap(session.open(URL(string: "https://f\($0).example")!))
    }
    let space = session.selectedSpaceID
    XCTAssertTrue(session.splitTabs(ids[0], ids[1], in: space))
    XCTAssertTrue(session.addToSplit(ids[2], beside: ids[1], edge: .right, in: space))
    let store = BrowserStore(session: session)
    store.focusSplitTab(ids[1])
    XCTAssertTrue(store.addCurrentPageAsFavorite())
    XCTAssertEqual(store.session.selectedPage?.tab.id, ids[1], "the favorited page stays on screen")
    XCTAssertEqual(store.session.selectedSpace.splits.first?.tabIDs, [ids[0], ids[2]])
    try store.session.validate()
  }
}
