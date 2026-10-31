// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SidebarIssue209VisualTests: XCTestCase {
  func testSixteenFavoritesAndTabs() async throws {
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled, "Visual capture requires explicit opt-in")
    var session = BrowserSession.fresh()
    let profile = session.selectedSpace.profileID
    for index in 0..<16 {
      XCTAssertNotNil(
        session.addFavorite(
          profileID: profile, originalURL: URL(string: "https://favorite\(index).example")!))
    }
    let pinned = try XCTUnwrap(session.open(URL(string: "https://pinned.example")!))
    XCTAssertTrue(
      session.moveTab(
        pinned, from: session.selectedSpaceID, to: session.selectedSpaceID, pinned: true))
    _ = session.open(URL(string: "https://today.example")!)
    let view = BrowserSidebar(store: BrowserStore(session: session))
      .frame(width: 240, height: 760)
      .background(Color(nsColor: .windowBackgroundColor))
    let mounted = try MountedChromeSidebar(
      view: view, size: NSSize(width: 240, height: 760), appearance: .aqua)
    defer { mounted.close() }
    _ = try await mounted.capture(to: URL(fileURLWithPath: "/tmp/arc-sidebar-16-favorites.png"))
  }
}
