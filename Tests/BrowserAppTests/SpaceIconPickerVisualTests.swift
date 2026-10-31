// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SpaceIconPickerVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Icon picker capture requires explicitly enabled GitHub Actions macOS CI")
  }

  func testPickerShowsEveryColumnInLightAndDark() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let picker = SpaceIconPicker(symbol: .constant("house"))
      let mounted = try MountedChromeSidebar(
        view: picker, size: NSSize(width: 330, height: 380), appearance: appearance)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: root.appendingPathComponent("space-icon-picker-\(name).png"),
        requiredText: ["Search icons", "General", "Work"])
    }
  }
}
