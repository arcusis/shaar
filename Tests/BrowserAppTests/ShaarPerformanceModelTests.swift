// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
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

  @Test func recordingFreezesMainThreadTasks() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    var includeSecond = false
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .longTasks:
        var items: [[String: Any]] = [
          ["name": "script evaluation", "startTime": 1130, "duration": 84]
        ]
        if includeSecond {
          items.append(["name": "event dispatch", "startTime": 1570, "duration": 56])
        }
        return ["items": items]
      case .vitalsInputs:
        return ["items": [["name": "ttfb", "value": 90], ["name": "fcp", "value": 400]]]
      default:
        return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarPerformanceModel(target: target, phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    model.startRecording()
    await model.refresh()
    #expect(model.capture == .recording)
    #expect(model.timelineTasks.map(\.name) == ["script evaluation"])
    #expect(model.inpMilliseconds == nil)
    includeSecond = true
    await model.refresh()
    #expect(model.timelineTasks.map(\.name) == ["script evaluation", "event dispatch"])
    #expect(ShaarPerformanceTimeline.lanes(for: model.timelineTasks).count == 1)
    model.stopRecording()
    #expect(model.capture == .stopped)
    #expect(model.timelineTasks.count == 2)
    model.startRecording()
    #expect(model.recordedTasks.isEmpty)
    phase2.close()
  }

  @Test func performancePanelRendersOffscreenForEachCapture() async throws {
    _ = NSApplication.shared
    let idleTarget = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let idlePhase = ShaarPhase2Model(target: idleTarget, transport: ShaarPhase2PendingTransport())
    let idle = ShaarPerformanceModel(target: idleTarget, phase2: idlePhase)
    let idleWide = try renderPerformance(idle, phase2: idlePhase, width: 900, height: 560)
    let idleNarrow = try renderPerformance(idle, phase2: idlePhase, width: 420, height: 720)

    let markedTarget = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let markedPhase = ShaarPhase2Model(
      target: markedTarget,
      transport: ShaarPhase2FixtureTransport { command in
        if case .vitalsInputs = command {
          return ["items": [["name": "fcp", "value": 400]]]
        }
        return ["items": []]
      })
    let marked = ShaarPerformanceModel(target: markedTarget, phase2: markedPhase)
    markedPhase.open()
    for _ in 0..<20 where !markedPhase.available { await Task.yield() }
    await marked.refresh()
    #expect(marked.fcpMilliseconds == 400)
    #expect(marked.timelineTasks.isEmpty)
    let emptyChart = try renderPerformance(marked, phase2: markedPhase, width: 900, height: 560)
    markedPhase.close()

    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let phase2 = ShaarPhase2Model(
      target: target,
      transport: ShaarPhase2FixtureTransport { command in
        switch command {
        case .longTasks:
          return [
            "items": [
              ["name": "script evaluation", "startTime": 1130, "duration": 84],
              ["name": "event dispatch", "startTime": 1140, "duration": 70],
            ]
          ]
        case .vitalsInputs:
          return ["items": [["name": "fcp", "value": 400], ["name": "lcp", "value": 900]]]
        default:
          return ["items": []]
        }
      })
    let model = ShaarPerformanceModel(target: target, phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    model.startRecording()
    await model.refresh()
    #expect(model.capture == .recording)
    #expect(model.timelineTasks.count == 2)
    let recording = try renderPerformance(model, phase2: phase2, width: 900, height: 560)
    model.stopRecording()
    #expect(model.capture == .stopped)
    let stopped = try renderPerformance(model, phase2: phase2, width: 900, height: 560)
    #expect(!idleWide.isEmpty)
    #expect(!idleNarrow.isEmpty)
    #expect(!emptyChart.isEmpty)
    #expect(!recording.isEmpty)
    #expect(!stopped.isEmpty)
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

@MainActor private func renderPerformance(
  _ model: ShaarPerformanceModel, phase2: ShaarPhase2Model, width: CGFloat, height: CGFloat
) throws -> Data {
  try VisualCapture.pngOffscreen(
    ShaarPerformancePanel(model: model, phase2: phase2),
    size: NSSize(width: width, height: height))
}
