// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@Suite @MainActor struct ShaarPerformanceModelTests {
  @Test func fixturesPopulateMetricsAndRouteHistory() async {
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
        return ["items": [["name": "script evaluation", "startTime": 1130, "duration": 84]]]
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
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarPerformanceModel(target: target, phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    await model.refresh()
    #expect(model.metrics["JSHeapUsedSize"] == 19_291_000)
    #expect(model.counters["nodes"] == 842)
    #expect(model.taskMilliseconds == 84)
    #expect(model.ttfbMilliseconds == 140 && model.fcpMilliseconds == 800)
    #expect(model.inpMilliseconds == 84)
    #expect(model.resourceCount == 2)
    #expect(model.samples.count == 1)

    model.receive([
      timeline(sequence: 1, type: "largest-contentful-paint", number: ["renderTime": 1800])
    ])
    model.receive([
      timeline(
        sequence: 2, type: "layout-shift", number: ["value": 0.02],
        flag: ["hadRecentInput": false])
    ])
    #expect(model.lcpMilliseconds == 1800 && model.cls == 0.02)
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/products")!)
    model.updateTarget(next, committed: true)
    phase2.updateTarget(next, committed: true)
    #expect(model.routes.first?.path == "/dashboard")
    #expect(model.routes.first?.lcpMilliseconds == 1800)
    #expect(model.path == "/products" && model.samples.isEmpty)
    phase2.close()
  }

  @Test func unavailableTransportKeepsPerformanceEmpty() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let phase2 = ShaarPhase2Model(target: target, transport: ShaarPhase2PendingTransport())
    let model = ShaarPerformanceModel(target: target, phase2: phase2)
    phase2.open()
    await model.refresh()
    #expect(model.samples.isEmpty && model.routes.isEmpty && !phase2.available)
    phase2.close()
  }

  private func timeline(
    sequence: UInt64, type: String, number: [String: Double], flag: [String: Bool] = [:]
  ) -> ShaarDevToolsPhase2Event {
    ShaarDevToolsPhase2Event(
      sequence: sequence, leaseID: 1, id: .timeline, localStorage: nil,
      text: ["type": type], number: number, flag: flag, items: [], truncated: false)
  }
}
