// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@MainActor final class ShaarPerformanceBudgetVisualTests: XCTestCase {
  func testRouteBudgetPanelRendersOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_PERFORMANCE_BUDGET_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen route budget capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let transport = ShaarPhase2FixtureTransport { command in
      switch command {
      case .performanceMetrics:
        return ["items": [["name": "JSHeapUsedSize", "value": 19_291_000]]]
      case .domCounters: return ["items": [], "nodes": 842, "documents": 1, "jsEventListeners": 42]
      case .longTasks: return ["items": []]
      case .vitalsInputs:
        return [
          "items": [
            ["name": "fcp", "value": 800], ["name": "interaction", "duration": 84],
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
    let phase2 = ShaarPhase2Model(target: target, transport: transport)
    phase2.open()
    for _ in 0..<30 where !phase2.available { await Task.yield() }
    let model = ShaarPerformanceModel(target: target, phase2: phase2)
    await model.refresh()
    model.receive([
      ShaarDevToolsPhase2Event(
        sequence: 1, leaseID: 1, id: .timeline, localStorage: nil,
        text: ["type": "largest-contentful-paint"], number: ["renderTime": 1800],
        flag: [:], items: [], truncated: false),
      ShaarDevToolsPhase2Event(
        sequence: 2, leaseID: 1, id: .timeline, localStorage: nil,
        text: ["type": "layout-shift"], number: ["value": 0.02],
        flag: ["hadRecentInput": false], items: [], truncated: false),
    ])
    model.updatePageSnapshot(
      PagePerformanceSnapshot(
        page: ["requests": 2.0, "javascriptBytes": 350_000.0], engineMetrics: []))
    XCTAssertEqual(model.javascriptBytes, 350_000)
    model.budgetConfiguration.routes = [
      ShaarRouteBudget(
        route: "/dashboard", lcpMilliseconds: 1_500, inpMilliseconds: 200,
        cls: 0.1, javascriptBytes: 500_000, requestCount: 1)
    ]
    XCTAssertEqual(
      model.budgetResult?.metrics.first(where: { $0.name == "JavaScript" })?.status, .pass)
    await Task.yield()
    await Task.yield()
    let evidence = URL(filePath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1246", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let page = DevelopmentPage.detect(url: target.url)
    for (suffix, appearance, scheme) in [
      ("light", NSAppearance.Name.aqua, ColorScheme.light),
      ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
    ] {
      let image = try VisualCapture.renderOffscreen(
        ShaarPerformancePanel(model: model, phase2: phase2)
          .frame(width: 1000, height: 620)
          .background(Color(nsColor: .windowBackgroundColor))
          .environment(\.colorScheme, scheme),
        size: NSSize(width: 1000, height: 620), appearance: appearance,
        to: evidence.appending(path: "after-performance-budget-results-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 1000)
      XCTAssertEqual(image.pixelsHigh, 620)
      let badge = try VisualCapture.renderOffscreen(
        DevelopmentModeLabel(page: page, budget: model.budgetResult)
          .environment(\.colorScheme, scheme),
        size: NSSize(width: 220, height: 44), appearance: appearance,
        to: evidence.appending(path: "after-dev-mode-budget-badge-\(suffix).png"))
      XCTAssertEqual(badge.pixelsWide, 143)
      XCTAssertEqual(badge.pixelsHigh, 28)
    }
    phase2.close()
  }
}
