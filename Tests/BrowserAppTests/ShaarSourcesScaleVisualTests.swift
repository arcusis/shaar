// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarSourcesScaleVisualTests: XCTestCase {
  func testFiveMiBSourceRendersOffscreen() async throws {
    guard let stage = ProcessInfo.processInfo.environment["SHAAR_SOURCES_SCALE_CAPTURE_STAGE"]
    else {
      throw XCTSkip("Offscreen Sources scale capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1243")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "https://example.com/large.js", "type": "Script"]]]
      case .resourceContent:
        return [
          "items": [], "body": ShaarPhase2FixtureTransport.fiveMiBSource,
          "base64Encoded": false,
        ]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    let phase2Ready = await phase2.waitUntilAvailable()
    XCTAssertTrue(phase2Ready)
    await model.refresh()
    if stage == "before" {
      XCTAssertNotNil(model.failure)
    } else {
      XCTAssertEqual(model.displayedContent?.utf8.count, 5 * 1_048_576)
    }
    try capture(model: model, at: root, name: "\(stage)-sources")
    phase2.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  func testInspectorFallbackRendersOffscreen() async throws {
    guard let stage = ProcessInfo.processInfo.environment["SHAAR_SOURCES_INSPECTOR_CAPTURE_STAGE"]
    else { throw XCTSkip("Offscreen Inspector source capture requires explicit opt-in") }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1243")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let url = "https://example.com/large.js"
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree: return ["items": [["url": url, "type": "Script"]]]
      case .resourceContent: throw InspectorFailure("Native reply exceeds 1 MiB")
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let inspectorContent: ShaarSourcesModel.InspectorContent?
    if stage == "before" {
      inspectorContent = nil
    } else {
      inspectorContent = { _, _ in (ShaarPhase2FixtureTransport.fiveMiBSource, false) }
    }
    let model = ShaarSourcesModel(
      phase2: phase2, inspectorContent: inspectorContent)
    phase2.open()
    let phase2Ready = await phase2.waitUntilAvailable()
    XCTAssertTrue(phase2Ready)
    await model.refresh()
    if stage == "before" {
      XCTAssertNotNil(model.failure)
    } else {
      XCTAssertEqual(model.displayedContent?.utf8.count, 5 * 1_048_576)
    }
    try capture(model: model, at: root, name: "\(stage)-inspector-sources")
    phase2.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture(model: ShaarSourcesModel, at root: URL, name: String) throws {
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .light ? "light" : "dark"
      let appearance: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
      let view = ShaarSourcesPanel(model: model, inspector: nil)
        .frame(width: 900, height: 600)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 900, height: 600), appearance: appearance,
        to: root.appending(path: "\(name)-\(suffix).png"))
    }
  }
}
