// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import XCTest

@testable import ArcusisBrowser

@MainActor
final class HebrewRTLGeometryTests: XCTestCase {
  func testSplitDropUsesLogicalLeadingAndTrailingEdges() {
    let size = CGSize(width: 400, height: 300)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 10, y: 150), in: size), .left)
    XCTAssertEqual(
      SplitDropZone.edge(at: CGPoint(x: 390, y: 150), in: size, isRightToLeft: true), .left)
    XCTAssertEqual(
      SplitDropZone.edge(at: CGPoint(x: 10, y: 150), in: size, isRightToLeft: true), .right)
    XCTAssertEqual(SplitEdge.forPhysicalRight(isRightToLeft: false), .right)
    XCTAssertEqual(SplitEdge.forPhysicalRight(isRightToLeft: true), .left)
  }

  func testSpaceSwipeAndPagerOffsetsFollowPhysicalFinger() {
    XCTAssertEqual(SpacePagerDecision.logicalDelta(-24, isRightToLeft: false), -24)
    XCTAssertEqual(SpacePagerDecision.logicalDelta(-24, isRightToLeft: true), 24)
  }

  func testSplitResizeReversesHorizontalLogicalDeltaInRTLOnly() {
    XCTAssertEqual(
      SplitResizeDecision.logicalDelta(30, isHorizontal: true, isRightToLeft: false), 30)
    XCTAssertEqual(
      SplitResizeDecision.logicalDelta(30, isHorizontal: true, isRightToLeft: true), -30)
    XCTAssertEqual(
      SplitResizeDecision.logicalDelta(30, isHorizontal: false, isRightToLeft: true), 30)
  }

  func testHiddenSidebarAndFavoriteMovesMirrorPhysicalDirection() {
    XCTAssertTrue(ProfileFavoritesGrid.moveLeftInOrder(physicalLeft: true, isRightToLeft: false))
    XCTAssertFalse(ProfileFavoritesGrid.moveLeftInOrder(physicalLeft: true, isRightToLeft: true))
    XCTAssertEqual(BrowserChromeLayout.pageWidth(windowWidth: 1_000, leadingWidth: 0), 1_000)
    let ltrPage = BrowserChromeLayout.initialWebContentFrame(
      size: CGSize(width: 1_000, height: 700), sidebarVisible: true,
      isRightToLeft: false, findBarVisible: false)
    let rtlPage = BrowserChromeLayout.initialWebContentFrame(
      size: CGSize(width: 1_000, height: 700), sidebarVisible: true,
      isRightToLeft: true, findBarVisible: false)
    XCTAssertEqual(ltrPage.minX, 208)
    XCTAssertEqual(rtlPage.minX, 8)
    XCTAssertEqual(ltrPage.width, rtlPage.width)
    let pageBounds = BrowserChromeLayout.initialWebContentFrame(
      size: CGSize(width: 1_000, height: 700), sidebarVisible: false,
      isRightToLeft: true, findBarVisible: true)
    let commandFrame = BrowserChromeLayout.commandPanelFrame(
      in: pageBounds, resultCount: 4, headerCount: 1)
    XCTAssertGreaterThanOrEqual(commandFrame.minX, pageBounds.minX)
    XCTAssertLessThanOrEqual(commandFrame.maxX, pageBounds.maxX)
    XCTAssertGreaterThanOrEqual(commandFrame.minY, pageBounds.minY)
    XCTAssertLessThanOrEqual(commandFrame.maxY, pageBounds.maxY)

    let first = FavoriteTile(
      id: UUID(), title: "First", url: URL(string: "https://first.example")!, image: nil)
    let second = FavoriteTile(
      id: UUID(), title: "Second", url: URL(string: "https://second.example")!, image: nil)
    XCTAssertEqual(
      ProfileFavoritesGrid.dropTargetBefore(
        targetID: second.id, dropX: 0, tileWidth: 100, favorites: [first, second]), second.id)
    XCTAssertNil(
      ProfileFavoritesGrid.dropTargetBefore(
        targetID: second.id, dropX: 0, tileWidth: 100, favorites: [first, second],
        isRightToLeft: true))
  }

  func testTitlebarDragRegionExcludesTrafficLightsAndMirroredToggle() {
    let bounds = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    let layout = NSRect(x: 0, y: 22, width: 1_000, height: 758)
    let lights = NSRect(x: 10, y: 760, width: 60, height: 20)
    let ltr = WindowDragRegion.titlebarDragFrame(
      contentBounds: bounds, contentLayoutRect: layout, trafficLightsFrame: lights)
    XCTAssertNotNil(ltr)
    XCTAssertFalse(ltr!.intersects(lights))
    XCTAssertGreaterThanOrEqual(
      ltr!.minX, lights.maxX + 8 + BrowserChromeLayout.titlebarAccessoryWidth)

    let rtl = WindowDragRegion.titlebarDragFrame(
      contentBounds: bounds, contentLayoutRect: layout, trafficLightsFrame: lights,
      isRightToLeft: true,
      trailingAccessoryWidth: BrowserChromeLayout.titlebarToggleLeading + 28)
    XCTAssertNotNil(rtl)
    XCTAssertFalse(rtl!.intersects(lights))
    XCTAssertLessThanOrEqual(
      rtl!.maxX, bounds.maxX - BrowserChromeLayout.titlebarToggleLeading - 28)
  }

  func testLocalizedEditMenuKeepsStableShortcutRoutingIdentity() {
    XCTAssertTrue(ShortcutCatalog.isEditMenu(identifier: "Edit", title: "עריכה"))
    XCTAssertTrue(ShortcutCatalog.isEditMenu(identifier: nil, title: "Edit"))
    XCTAssertFalse(ShortcutCatalog.isEditMenu(identifier: "View", title: "תצוגה"))

    let menu = NativeBrowserHost.makeMenu(target: NSObject())
    XCTAssertTrue(
      menu.items.compactMap(\.submenu).contains {
        $0.identifier?.rawValue == "Edit"
          && ShortcutCatalog.isEditMenu(
            identifier: $0.identifier?.rawValue, title: $0.title)
      })
  }
}
