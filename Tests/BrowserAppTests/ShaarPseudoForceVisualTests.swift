// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarPseudoForceVisualTests: XCTestCase {
  func testForceStateControlsRenderOffscreen() throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_PSEUDO_CAPTURE"] ?? ""
    guard phase == "before" || phase == "after" else {
      throw XCTSkip("Offscreen force-state capture requires SHAAR_PSEUDO_CAPTURE=before or after")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1277")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let forced: Set<String> = phase == "after" ? ["hover"] : []
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let control = InspectorPseudoForceControls(forced: forced, toggle: { _ in })
        .frame(width: 320, height: 78)
        .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        control, size: NSSize(width: 320, height: 78), appearance: appearance,
        to: root.appending(path: "\(phase)-force-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 320)
      XCTAssertEqual(image.pixelsHigh, 78)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
