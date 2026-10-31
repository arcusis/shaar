// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ExtensionManagerVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Extension manager capture requires explicitly enabled GitHub Actions macOS CI")
  }

  func testRowsShowStatePinAndControlsInLightAndDark() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    let items = [
      sample("Bitwarden Password Manager", enabled: true),
      sample("Surfshark VPN", enabled: true),
      sample("Grammarly", enabled: false),
    ]
    let view = VStack(spacing: 2) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        ExtensionRow(
          item: item, icon: nil, pinned: index == 0, canRun: true,
          actions: ExtensionRowActions(
            run: {}, setPinned: { _ in }, setEnabled: { _ in }, showDetails: {}))
      }
    }
    .padding(8)
    .frame(width: 320, height: 132, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let mounted = try MountedChromeSidebar(
        view: view, size: NSSize(width: 320, height: 132), appearance: appearance)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: root.appendingPathComponent("extension-manager-\(name).png"),
        requiredText: ["Bitwarden", "Surfshark", "Grammarly"])
    }
  }

  private func sample(_ name: String, enabled: Bool) -> ManagedExtension {
    ManagedExtension(
      id: String(repeating: "a", count: 32), name: name, version: "1.0", description: "",
      enabled: enabled, mayDisable: true, permissions: [], hostPermissions: [])
  }
}
