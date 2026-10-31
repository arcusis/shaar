// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

@testable import ArcusisBrowser

final class PageResizeLayoutTests: XCTestCase {
  func testPageWidthTracksWindowAndSidebarChanges() {
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 1200, leadingWidth: 240), 960)
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 1500, leadingWidth: 240), 1260)
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 1200, leadingWidth: 0), 1200)
  }

  func testPageWidthUsesActualLibraryDrawerWidth() {
    let drawer = BrowserChromeLayout.libraryWidth(windowWidth: 1200, spaces: false)
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 1200, leadingWidth: drawer), 812)
  }

  func testPageWidthNeverBecomesNegative() {
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 200, leadingWidth: 240), 0)
  }
}
