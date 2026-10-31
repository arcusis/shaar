// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShortcutVisualTests: XCTestCase {
  func testShortcutsPaneCapture() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires CI opt-in")
    let size = NSSize(width: 720, height: 650)
    let view = SettingsShortcutsPane()
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
    let mounted = try MountedChromeSidebar(view: view, size: size, appearance: .aqua)
    defer { mounted.close() }
    _ = try await mounted.capture(
      to: URL(fileURLWithPath: "/tmp/shortcuts-pane.png"),
      requiredText: ["Shortcuts", "Search shortcuts", "New window"])
  }
}
