import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class BrowserSplitStoreTests: XCTestCase {
  func testShortcutUsesMostRecentlySelectedOtherTab() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    let third = try XCTUnwrap(session.open(URL(string: "https://three.example")!))
    let store = BrowserStore(session: session)
    let space = session.selectedSpaceID
    store.perform(.tab(space: space, tab: first))
    store.perform(.tab(space: space, tab: second))
    store.splitSelectedTab()
    XCTAssertEqual(store.selectedSplit?.tabIDs, [second, first])
    store.focusSplitTab(first)
    XCTAssertEqual(store.session.selectedPage?.tab.id, first)
    store.unsplitTab(first)
    XCTAssertNil(store.selectedSplit)
    XCTAssertEqual(store.session.selectedPage?.tab.id, second)
    XCTAssertTrue(store.session.selectedSpace.tabs.contains { $0.id == third })
  }
}
