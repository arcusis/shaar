// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarMemoryVisualTests: XCTestCase {
  func testMemoryRendersOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_MEMORY_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Memory capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1317")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let gated = makeShell(target)
      gated.open(inspector: inspector)
      gated.section = .memory
      await gated.memory.takeSnapshot()
      XCTAssertEqual(gated.memory.support, .needsEngine)
      try capture(
        ShaarDevToolsPanel(model: gated, inspector: inspector, openChromium: {}),
        named: "before-memory-gated-\(suffix)", scheme: scheme, appearance: appearance, root: root)
      gated.close()

      let populated = makeShell(target)
      populated.open(inspector: inspector)
      populated.section = .memory
      try populated.memory.loadSnapshot(ShaarMemoryFixture.snapshotData())
      try populated.memory.loadAllocationProfile(ShaarMemoryFixture.allocationProfileData())
      try capture(
        ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
        named: "after-memory-summary-\(suffix)", scheme: scheme, appearance: appearance, root: root)
      populated.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeShell(_ target: SiteControlTarget) -> ShaarDevToolsModel {
    let defaults = UserDefaults(suiteName: "ShaarMemoryCapture.\(UUID().uuidString)")!
    return ShaarDevToolsModel(target: target, layoutDefaults: defaults)
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name, root: URL
  ) throws {
    let view =
      panel
      .frame(width: 1040, height: 620)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 620)
  }
}
