// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
