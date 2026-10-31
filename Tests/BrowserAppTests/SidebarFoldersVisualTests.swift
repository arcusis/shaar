// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SidebarFoldersVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Sidebar folder capture requires explicitly enabled GitHub Actions macOS CI")
  }

  func testCapturesFoldersInPinnedAndTodaySections() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    let store = try makeStore()
    let spaceID = store.session.selectedSpaceID
    let pinnedFolder = try XCTUnwrap(
      store.createFolder(name: "Projects", in: spaceID, section: .pinned))
    let todayFolder = try XCTUnwrap(
      store.createFolder(name: "Reading", in: spaceID, section: .today))
    let tabs = store.session.selectedSpace.tabs
    for tab in tabs.prefix(2) {
      XCTAssertTrue(store.moveTab(tab.id, from: spaceID, to: spaceID, folderID: pinnedFolder))
    }
    for tab in tabs.dropFirst(3).prefix(2) {
      XCTAssertTrue(store.moveTab(tab.id, from: spaceID, to: spaceID, folderID: todayFolder))
    }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let mounted = try MountedChromeSidebar(
        view: BrowserSidebar(store: store),
        size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 620), appearance: appearance)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: root.appendingPathComponent("sidebar-folders-\(name).png"),
        requiredText: ["Projects", "Reading"])
    }
  }

  private func makeStore() throws -> BrowserStore {
    let profileID = UUID()
    let titles = ["Roadmap", "Design review", "Team notes", "Swift docs", "Arc tips", "Weather"]
    let tabs = titles.enumerated().map { index, title in
      BrowserTab(
        url: URL(string: "https://example\(index).com")!, title: title, isPinned: index < 3)
    }
    let space = BrowserSpace(
      profileID: profileID, name: "Work", symbol: "briefcase", tint: .ocean, tabs: tabs,
      selectedTabID: tabs.last?.id)
    let session = try BrowserSession(
      profiles: [BrowserProfile(id: profileID, name: "Work")], spaces: [space],
      selectedSpaceID: space.id)
    return BrowserStore(session: session)
  }
}
