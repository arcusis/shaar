// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import XCTest

@testable import ArcusisBrowser

final class TabRecencyTests: XCTestCase {
  func testRecencyIsScopedAndDropsClosedTabs() {
    let space = UUID()
    let other = UUID()
    let a = UUID()
    let b = UUID()
    let c = UUID()
    var history = TabRecency()
    history.record(a, in: space)
    history.record(b, in: space)
    history.record(a, in: other)
    XCTAssertEqual(history.ordered(in: space, available: [a, b, c]), [b, a, c])
    XCTAssertEqual(history.ordered(in: space, available: [a, c]), [a, c])
    XCTAssertEqual(history.ordered(in: other, available: [b, a]), [a, b])
  }

  func testCycleWrapsInBothDirections() {
    XCTAssertEqual(TabRecency.cycle(0, count: 3, reverse: false), 1)
    XCTAssertEqual(TabRecency.cycle(0, count: 3, reverse: true), 2)
    XCTAssertEqual(TabRecency.cycle(2, count: 3, reverse: false), 0)
    XCTAssertEqual(TabRecency.cycle(0, count: 0, reverse: true), 0)
  }
}

@MainActor
final class TabSwitcherFavoriteTests: XCTestCase {
  func testControlTabSwitchesBetweenOpenFavoritePagesWithoutOrdinaryTabs() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpace
    XCTAssertTrue(space.tabs.isEmpty)
    let first = try XCTUnwrap(
      store.session.addFavorite(
        profileID: space.profileID, originalURL: URL(string: "https://first.example")!))
    let second = try XCTUnwrap(
      store.session.addFavorite(
        profileID: space.profileID, originalURL: URL(string: "https://second.example")!))
    XCTAssertTrue(store.session.selectFavorite(second, in: space.id))
    let firstTab = try XCTUnwrap(store.session.favoritePage(for: first)?.tab.id)
    let secondTab = try XCTUnwrap(store.session.favoritePage(for: second)?.tab.id)

    let switcher = TabSwitcherController()
    switcher.advance(store: store, reverse: false)

    XCTAssertEqual(switcher.choices, [secondTab, firstTab])
    switcher.commit(store: store)
    XCTAssertEqual(store.session.selectedFavorite?.id, first)
  }
}
