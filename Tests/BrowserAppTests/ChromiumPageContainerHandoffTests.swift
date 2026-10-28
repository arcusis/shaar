import AppKit
import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ChromiumPageContainerHandoffTests: XCTestCase {
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
