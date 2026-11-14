// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ChromiumPageContainerHandoffTests: XCTestCase {
  private final class MouseDownView: NSView {
    var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
      mouseDownCount += 1
    }
  }

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

  func testOutgoingContainerHandsPageToMostRecentlySelectedContainer() {
    let tabID = UUID()
    let page = NSView()
    let stale = ChromiumPageContainerView()
    let latest = ChromiumPageContainerView()
    let outgoing = ChromiumPageContainerView()

    stale.select(page, tabID: tabID, liveTabs: [tabID])
    latest.select(page, tabID: tabID, liveTabs: [tabID])
    outgoing.select(page, tabID: tabID, liveTabs: [tabID])
    XCTAssertTrue(ChromiumPageContainerView.latestLiveContainer(for: tabID) === outgoing)

    outgoing.dismantle()

    XCTAssertTrue(ChromiumPageContainerView.latestLiveContainer(for: tabID) === latest)
    XCTAssertTrue(page.superview === latest)
    XCTAssertFalse(page.superview === stale)
  }

  func testMultiTabSelectionRoundTripRetainsOnlyLivePages() {
    let firstID = UUID()
    let secondID = UUID()
    let firstPage = NSView()
    let secondPage = NSView()
    let container = ChromiumPageContainerView()

    XCTAssertTrue(container.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID]))
    XCTAssertTrue(container.select(secondPage, tabID: secondID, liveTabs: [firstID, secondID]))
    XCTAssertTrue(firstPage.isHidden)
    XCTAssertFalse(secondPage.isHidden)

    XCTAssertTrue(container.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID]))
    XCTAssertFalse(firstPage.isHidden)
    XCTAssertTrue(secondPage.isHidden)
    XCTAssertTrue(firstPage.superview === container)
    XCTAssertTrue(secondPage.superview === container)

    _ = container.select(firstPage, tabID: firstID, liveTabs: [firstID])
    XCTAssertNil(secondPage.superview)
    XCTAssertTrue(container.pageView === firstPage)
  }

  func testMissingNativeViewDoesNotDetachOtherLiveTabPages() {
    let firstID = UUID()
    let secondID = UUID()
    let firstPage = NSView()
    let secondPage = NSView()
    let container = ChromiumPageContainerView()

    _ = container.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID])
    _ = container.select(secondPage, tabID: secondID, liveTabs: [firstID, secondID])

    XCTAssertFalse(container.select(nil, tabID: secondID, liveTabs: [firstID, secondID]))

    XCTAssertNil(container.pageView)
    XCTAssertTrue(firstPage.isHidden)
    XCTAssertTrue(secondPage.isHidden)
    XCTAssertTrue(firstPage.superview === container)
    XCTAssertTrue(secondPage.superview === container)

    XCTAssertTrue(container.select(secondPage, tabID: secondID, liveTabs: [firstID, secondID]))
    XCTAssertFalse(secondPage.isHidden)
    XCTAssertTrue(firstPage.isHidden)

    XCTAssertFalse(container.select(nil, tabID: secondID, liveTabs: [firstID]))
    XCTAssertNil(secondPage.superview)
    XCTAssertTrue(firstPage.superview === container)
    XCTAssertTrue(firstPage.isHidden)
  }

  func testPrivatePageSelectionRetainsOtherTabsAndHandsOffOnTeardown() {
    let firstID = UUID()
    let secondID = UUID()
    let firstPage = NSView()
    let secondPage = NSView()
    let outgoing = ChromiumPageContainerView()
    let incoming = ChromiumPageContainerView()

    XCTAssertTrue(
      outgoing.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID]))
    XCTAssertTrue(
      outgoing.select(secondPage, tabID: secondID, liveTabs: [firstID, secondID]))
    XCTAssertTrue(firstPage.isHidden)
    XCTAssertTrue(firstPage.superview === outgoing)
    XCTAssertFalse(secondPage.isHidden)

    XCTAssertTrue(
      incoming.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID]))
    outgoing.select(firstPage, tabID: firstID, liveTabs: [firstID, secondID])
    ChromiumPageContainerView.dismantlePrivatePage(outgoing)

    XCTAssertTrue(firstPage.superview === incoming)
    XCTAssertTrue(incoming.pageView === firstPage)
    XCTAssertNil(secondPage.superview)
  }

  func testContainerLayoutKeepsNativeDockClickAreaUncovered() {
    let tab = UUID()
    let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    let container = ChromiumPageContainerView(frame: frame)
    let page = NSView(frame: frame)
    let frontend = MouseDownView(frame: frame)
    let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { window.close() }
    _ = container.select(page, tabID: tab, liveTabs: [tab])
    container.addSubview(frontend, positioned: .below, relativeTo: page)
    page.frame = NSRect(x: 0, y: 0, width: 600, height: 700)

    container.layout()

    XCTAssertEqual(page.frame.width, 600)
    let target = container.hitTest(NSPoint(x: 900, y: 350))
    XCTAssertTrue(target === frontend)
    XCTAssertFalse(window.isVisible)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 900, y: 350), modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1)
    XCTAssertNotNil(event)
    // AppKit does not dispatch a window-system mouse event to a hidden window.
    // Deliver the synthesized event to the view selected by the real hit test.
    if let event { target?.mouseDown(with: event) }
    XCTAssertEqual(frontend.mouseDownCount, 1)
    XCTAssertFalse(window.isVisible)

    page.frame = NSRect(x: 0, y: 280, width: 1000, height: 420)
    container.layout()
    XCTAssertEqual(page.frame.minY, 280)
    XCTAssertTrue(container.hitTest(NSPoint(x: 500, y: 80)) === frontend)
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
