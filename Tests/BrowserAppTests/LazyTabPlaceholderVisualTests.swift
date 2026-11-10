// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class LazyTabPlaceholderVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Lazy tab capture requires explicitly enabled GitHub Actions macOS CI")
  }

  func testSavedBackgroundTabShowsCachedIconWithoutMaterializing() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    let profile = BrowserProfile(name: "Reading")
    let active = BrowserTab(url: URL(string: "https://active.example")!, title: "Active page")
    let background = BrowserTab(
      url: URL(string: "https://background.example")!, title: "Background page")
    let space = BrowserSpace(
      profileID: profile.id, name: "Reading", symbol: "book", tint: .ocean,
      tabs: [active, background], selectedTabID: active.id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let cacheDirectory = FileManager.default.temporaryDirectory.appending(
      path: "lazy-tabs-icons-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let store = BrowserStore(session: session)
    store.faviconCache = FaviconCache(directory: cacheDirectory)
    let mounted = try MountedChromeSidebar(
      view: BrowserSidebar(store: store),
      size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 620), appearance: .aqua)
    defer { mounted.close() }

    XCTAssertNil(store.favicon(for: background, profileID: profile.id))
    _ = try await mounted.capture(
      to: root.appendingPathComponent("lazy-tab-before-icon.png"),
      requiredText: ["Background"])

    store.faviconCache?.store(
      FaviconFixture.icon(.red), for: background.id, profileID: profile.id,
      host: background.url.host)
    XCTAssertNotNil(store.favicon(for: background, profileID: profile.id))
    _ = try await mounted.capture(
      to: root.appendingPathComponent("lazy-tab-after-icon.png"),
      requiredText: ["Background"])
  }
}
