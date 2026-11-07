// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarRenderingVisualTests: XCTestCase {
  func testRenderingDrawerRendersOffscreen() async throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_RENDERING_CAPTURE"] ?? ""
    guard phase == "before" || phase == "after" else {
      throw XCTSkip("Offscreen rendering capture requires SHAAR_RENDERING_CAPTURE=before or after")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1314")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/rendering")!)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let fixture = ShaarRenderingFixtureTransport()
      fixture.overlayAnswer = phase == "after"
      let shell = ShaarDevToolsModel(target: target, renderingTransport: fixture)
      shell.section = .rendering
      await shell.rendering.prepare()
      if phase == "after" {
        shell.rendering.colorScheme = .dark
        shell.rendering.motion = .reduce
        shell.rendering.cssMedia = .print
        shell.rendering.paintRects = true
        await shell.rendering.settled()
      }
      let panel = ShaarDevToolsPanel(model: shell, inspector: nil, openChromium: {})
        .frame(width: 1040, height: 520)
        .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        panel, size: NSSize(width: 1040, height: 520), appearance: appearance,
        to: root.appending(path: "\(phase)-rendering-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 1040)
      XCTAssertEqual(image.pixelsHigh, 520)
      XCTAssertNil(shell.rendering.failure)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
