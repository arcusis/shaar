// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@MainActor final class ShaarPerformanceVisualTests: XCTestCase {
  func testPerformanceRendersOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_PERFORMANCE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Performance capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1134")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .performanceMetrics:
        return [
          "items": [
            ["name": "JSHeapUsedSize", "value": 19_291_000],
            ["name": "TaskDuration", "value": 0.24],
          ]
        ]
      case .domCounters:
        return ["items": [], "documents": 1, "nodes": 842, "jsEventListeners": 126]
      case .longTasks:
        return [
          "items": [
            ["name": "script evaluation", "startTime": 1130, "duration": 84],
            ["name": "event dispatch", "startTime": 1570, "duration": 56],
          ]
        ]
      case .vitalsInputs:
        return [
          "items": [
            ["name": "ttfb", "value": 140], ["name": "fcp", "value": 800],
            ["name": "interaction", "startTime": 1800, "duration": 84, "interactionID": 1],
          ]
        ]
      case .resourceTree:
        return [
          "items": [
            ["url": "https://example.com/app.js", "type": "Script", "mimeType": "text/javascript"],
            ["url": "https://example.com/logo.svg", "type": "Image", "mimeType": "image/svg+xml"],
          ]
        ]
      default: return ["items": []]
      }
    }
    let inspector = InspectorModel(target: target, engine: nil)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let pending = ShaarDevToolsModel(target: target)
      pending.section = .performance
      pending.open(inspector: inspector)
      try capture(
        ShaarDevToolsPanel(model: pending, inspector: inspector, openChromium: {}),
        named: "after-performance-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      pending.close()

      let live = ShaarDevToolsModel(target: target, phase2Transport: fixture)
      live.section = .performance
      live.open(inspector: inspector)
      for _ in 0..<30 where !live.phase2.available { await Task.yield() }
      XCTAssertTrue(live.phase2.available)
      await live.performance.refresh()
      live.performance.receive([
        ShaarDevToolsPhase2Event(
          sequence: 1, leaseID: 1, id: .timeline, localStorage: nil,
          text: ["type": "largest-contentful-paint"], number: ["renderTime": 1800],
          flag: [:], items: [], truncated: false),
        ShaarDevToolsPhase2Event(
          sequence: 2, leaseID: 1, id: .timeline, localStorage: nil,
          text: ["type": "layout-shift"], number: ["value": 0.02],
          flag: ["hadRecentInput": false], items: [], truncated: false),
      ])
      live.performance.startRecording()
      await live.performance.refresh()
      live.performance.stopRecording()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-performance-recording-\(suffix)", scheme: scheme,
        appearance: appearance, root: root, height: 640)
      live.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
    root: URL, height: CGFloat = 440
  ) throws {
    let view =
      panel
      .frame(width: 1040, height: height)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: height), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, Int(height))
  }
}
