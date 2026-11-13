// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarBoxModelVisualTests: XCTestCase {
  func testBoxModelEditLabelsIncludeRegionAndSide() {
    XCTAssertEqual(
      InspectorBoxModel.editAccessibilityLabel(region: "padding", index: 0), "Edit Padding Top")
    XCTAssertEqual(
      InspectorBoxModel.editAccessibilityLabel(region: "border", index: 1), "Edit Border Right")
  }

  func testBoxModelRendersOffscreen() throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_BOX_CAPTURE"] ?? ""
    guard phase == "before" || phase == "after" else {
      throw XCTSkip("Offscreen box capture requires SHAAR_BOX_CAPTURE=before or after")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1271")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let box = InspectorSelection.Box(
      width: 180, height: 48, contentWidth: 136, contentHeight: 24,
      margin: ["8px", "12px", "8px", "12px"], border: Array(repeating: "2px", count: 4),
      padding: ["10px", "20px", "10px", "20px"])
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let diagram = InspectorBoxModel(
        box: box, editingEdge: phase == "after" ? "padding0" : nil
      )
      .frame(width: 320, height: 142)
      .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        diagram, size: NSSize(width: 320, height: 142), appearance: appearance,
        to: root.appending(path: "\(phase)-box-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 320)
      XCTAssertEqual(image.pixelsHigh, 142)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
