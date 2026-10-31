// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import XCTest

@testable import ArcusisBrowser

final class BrowserChromeLayoutTests: XCTestCase {
  func testLibraryWidthsPreservePageSliver() {
    XCTAssertEqual(BrowserChromeLayout.libraryWidth(windowWidth: 1200, spaces: false), 388)
    XCTAssertEqual(BrowserChromeLayout.libraryWidth(windowWidth: 1200, spaces: true), 1176)
    XCTAssertEqual(BrowserChromeLayout.libraryWidth(windowWidth: 300, spaces: false), 276)
    XCTAssertEqual(BrowserChromeLayout.libraryWidth(windowWidth: 10, spaces: true), 0)
  }

  func testLauncherCentersOverWebContentWithSidebarVisible() {
    let content = CGRect(x: 240, y: 55, width: 950, height: 715)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 8)

    XCTAssertEqual(frame.midX, content.midX)
    XCTAssertEqual(frame.midY, content.midY)
    XCTAssertEqual(frame.width, 580)
  }

  func testMinimumWindowKeepsLauncherInsideWebContent() {
    let content = CGRect(x: 240, y: 55, width: 510, height: 455)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 8)

    XCTAssertLessThanOrEqual(frame.width, content.width)
    XCTAssertLessThanOrEqual(frame.height, content.height)
    XCTAssertGreaterThanOrEqual(frame.minX, content.minX)
    XCTAssertLessThanOrEqual(frame.maxX, content.maxX)
    XCTAssertGreaterThanOrEqual(frame.minY, content.minY)
    XCTAssertLessThanOrEqual(frame.maxY, content.maxY)
    XCTAssertEqual(frame.midY, content.midY)
  }

  func testHiddenSidebarCentersOverInsetPageArea() {
    let content = CGRect(x: 10, y: 55, width: 1180, height: 715)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 8)

    XCTAssertEqual(frame.midX, content.midX)
    XCTAssertEqual(frame.midY, content.midY)
  }

  func testFindBarMovesLauncherCenterIntoRemainingPageHeight() {
    let content = CGRect(x: 240, y: 105, width: 510, height: 405)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 20)

    XCTAssertEqual(frame.midY, content.midY)
    XCTAssertGreaterThanOrEqual(frame.minY, content.minY)
    XCTAssertLessThanOrEqual(frame.maxY, content.maxY)
  }

  func testNarrowContentConstrainsPanelWidth() {
    let content = CGRect(x: 240, y: 55, width: 510, height: 455)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 4)

    XCTAssertEqual(frame.width, 510)
    XCTAssertEqual(frame.midX, content.midX)
  }

  func testTallResultsUseAvailableHeightAndRemainCentered() {
    let content = CGRect(x: 10, y: 55, width: 1180, height: 1135)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 100)

    XCTAssertEqual(
      frame.height,
      BrowserChromeLayout.commandChromeHeight + BrowserChromeLayout.preferredResultsHeight)
    XCTAssertEqual(frame.midY, content.midY)
  }

  func testShortWindowBoundsResultsToRemainingPanelHeight() {
    let content = CGRect(x: 10, y: 105, width: 980, height: 185)
    let frame = BrowserChromeLayout.commandPanelFrame(in: content, resultCount: 100)

    XCTAssertLessThanOrEqual(frame.height, content.height)
    XCTAssertEqual(frame.midY, content.midY)
  }
}
