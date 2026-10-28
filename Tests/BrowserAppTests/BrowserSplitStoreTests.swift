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

  func testDroppingTabsBuildsAndSeparatesSplits() throws {
    var session = BrowserSession.fresh()
    let ids = try (0..<5).map { try XCTUnwrap(session.open(URL(string: "https://t\($0).example")!)) }
    let store = BrowserStore(session: session)
    let space = store.session.selectedSpaceID
    store.perform(.tab(space: space, tab: ids[0]))

    _ = store.beginTabDrag(ids[1], spaceID: space, fromSplitPane: false)
    XCTAssertFalse(store.canDropTab(beside: ids[1]))
    XCTAssertTrue(store.dropTab(beside: ids[0], edge: .right))
    XCTAssertNil(store.tabDrag)
    _ = store.beginTabDrag(ids[2], spaceID: space, fromSplitPane: false)
    XCTAssertTrue(store.dropTab(beside: ids[1], edge: .bottom))
    _ = store.beginTabDrag(ids[3], spaceID: space, fromSplitPane: false)
    XCTAssertTrue(store.dropTab(beside: ids[0], edge: .top))
    XCTAssertEqual(store.selectedSplit?.tabIDs.count, 4)
    _ = store.beginTabDrag(ids[4], spaceID: space, fromSplitPane: false)
    XCTAssertFalse(store.canDropTab(beside: ids[0]), "a full split takes no new tabs")

    _ = store.beginTabDrag(ids[2], spaceID: space, fromSplitPane: true)
    XCTAssertTrue(store.canDropTab(beside: ids[0]), "panes can rearrange inside a full split")
    XCTAssertTrue(store.acceptSidebarDrop(
      .tab(sessionID: store.dragSessionID, sourceSpaceID: space, tabID: ids[2]), into: space))
    XCTAssertEqual(Set(try XCTUnwrap(store.selectedSplit).tabIDs), [ids[0], ids[1], ids[3]])
  }

  func testDropEdgeFollowsNearestSide() {
    let size = CGSize(width: 400, height: 300)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 20, y: 150), in: size), .left)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 390, y: 150), in: size), .right)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 200, y: 10), in: size), .top)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 200, y: 290), in: size), .bottom)
  }
}
