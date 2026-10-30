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
