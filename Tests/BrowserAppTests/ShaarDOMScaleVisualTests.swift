// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDOMScaleVisualTests: XCTestCase {
  func testLargeTreeRendersOffscreen() async throws {
    guard let stage = ProcessInfo.processInfo.environment["SHAAR_DOM_SCALE_CAPTURE_STAGE"] else {
      throw XCTSkip("Offscreen DOM scale capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1243")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let fixture = DOMFixtureTransport()
    fixture.document = DOMFixtureTransport.twentyThousandNodeDocument()
    let model = ShaarDOMTreeModel(target: target, transport: fixture)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    model.open()
    for _ in 0..<100 where model.rootID == nil && model.failure == nil { await Task.yield() }
    if stage == "before" {
      XCTAssertNotNil(model.failure)
    } else {
      XCTAssertEqual(model.rows.count, 20_000)
    }
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .light ? "light" : "dark"
      let appearance: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
      let view = ShaarDOMTreePanel(model: model, inspector: inspector, openChromium: {})
        .frame(width: 900, height: 600)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 900, height: 600), appearance: appearance,
        to: root.appending(path: "\(stage)-dom-\(suffix).png"))
    }
    model.close()
    inspector.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
