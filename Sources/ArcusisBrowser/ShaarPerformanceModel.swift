// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

struct ShaarPerformanceTask: Identifiable, Equatable {
  let id: String
  let name: String
  let start: Double
  let duration: Double
}

struct ShaarPerformanceSample: Equatable {
  let heapBytes: Double?
  let nodes: Int?
  let busySeconds: Double?
}

struct ShaarPerformanceRoute: Identifiable, Equatable {
  let id: UUID
  let path: String
  let capturedAt: Date
  let lcpMilliseconds: Double?
}

@MainActor @Observable
final class ShaarPerformanceModel {
  private(set) var path: String
  private(set) var lcpMilliseconds: Double?
  private(set) var inpMilliseconds: Double?
  private(set) var cls = 0.0
  private(set) var ttfbMilliseconds: Double?
  private(set) var fcpMilliseconds: Double?
  private(set) var metrics: [String: Double] = [:]
  private(set) var counters: [String: Int] = [:]
  private(set) var tasks: [ShaarPerformanceTask] = []
  private(set) var resourceTypes: [String: Int] = [:]
  private(set) var resourcesTruncated = false
  private(set) var samples: [ShaarPerformanceSample] = []
  private(set) var routes: [ShaarPerformanceRoute] = []
  private(set) var loading = false
  var failure: String?
  @ObservationIgnored private let phase2: ShaarPhase2Model
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var lastSequence: UInt64 = 0

  init(target: SiteControlTarget, phase2: ShaarPhase2Model) {
    self.phase2 = phase2
    path = Self.path(for: target.url)
  }

  var taskMilliseconds: Double { tasks.reduce(0) { $0 + $1.duration } }
  var latestSample: ShaarPerformanceSample? { samples.last }
  var resourceCount: Int { resourceTypes.values.reduce(0, +) }

  func updateTarget(_ target: SiteControlTarget, committed: Bool) {
    guard Self.path(for: target.url) != path || committed else { return }
    if hasPageData {
      routes.insert(
        ShaarPerformanceRoute(
          id: UUID(), path: path, capturedAt: Date(), lcpMilliseconds: lcpMilliseconds),
        at: 0)
      if routes.count > 20 { routes.removeLast(routes.count - 20) }
    }
    path = Self.path(for: target.url)
    clearPage()
  }

  func reset() {
    clearPage()
    routes.removeAll()
  }

  func refresh() async {
    guard phase2.available, !loading else { return }
    let generation = generation
    loading = true
    defer {
      if generation == self.generation { loading = false }
    }
    do {
      let metricReply = try await phase2.execute(.performanceMetrics)
      let counterReply = try await phase2.execute(.domCounters)
      let taskReply = try await phase2.execute(.longTasks)
      let vitalReply = try await phase2.execute(.vitalsInputs)
      let resourceReply = try await phase2.execute(.resourceTree)
      guard generation == self.generation else { return }
      metrics = Dictionary(
        metricReply.items.compactMap { item in
          guard let name = item.text["name"], let value = item.number["value"] else { return nil }
          return (name, value)
        }, uniquingKeysWith: { _, latest in latest })
      counters = counterReply.counters
      tasks = taskReply.items.enumerated().compactMap { index, item in
        guard let start = item.number["startTime"],
          let duration = item.number["duration"]
        else { return nil }
        return ShaarPerformanceTask(
          id: "\(index)-\(start)", name: item.text["name"] ?? "Long task",
          start: start, duration: duration)
      }
      resourceTypes = Dictionary(
        resourceReply.items.compactMap { $0.text["type"] }.map { ($0, 1) },
        uniquingKeysWith: +)
      resourcesTruncated = resourceReply.truncated || resourceReply.hasMore == true
      receiveVitals(vitalReply.items)
      receive(phase2.events)
      samples.append(
        ShaarPerformanceSample(
          heapBytes: metrics["JSHeapUsedSize"], nodes: counters["nodes"],
          busySeconds: metrics["TaskDuration"]))
      if samples.count > 60 { samples.removeFirst(samples.count - 60) }
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      if generation == self.generation { failure = error.localizedDescription }
    }
  }

  func receive(_ events: [ShaarDevToolsPhase2Event]) {
    for event in events where event.sequence > lastSequence {
      lastSequence = event.sequence
      guard event.id == .timeline else { continue }
      if event.text["type"] == "largest-contentful-paint" {
        let renderTime = event.number["renderTime"] ?? 0
        lcpMilliseconds = renderTime > 0 ? renderTime : event.number["loadTime"]
      } else if event.text["type"] == "layout-shift",
        event.flag["hadRecentInput"] == false
      {
        cls += event.number["value"] ?? 0
      }
    }
  }

  private func receiveVitals(_ items: [ShaarDevToolsPhase2Item]) {
    for item in items {
      switch item.text["name"] {
      case "ttfb": ttfbMilliseconds = item.number["value"]
      case "fcp": fcpMilliseconds = item.number["value"]
      default:
        if let duration = item.number["duration"] {
          inpMilliseconds = max(inpMilliseconds ?? 0, duration)
        }
      }
    }
  }

  private var hasPageData: Bool {
    lcpMilliseconds != nil || fcpMilliseconds != nil || !samples.isEmpty
  }

  private func clearPage() {
    generation += 1
    lastSequence = 0
    lcpMilliseconds = nil
    inpMilliseconds = nil
    cls = 0
    ttfbMilliseconds = nil
    fcpMilliseconds = nil
    metrics.removeAll()
    counters.removeAll()
    tasks.removeAll()
    resourceTypes.removeAll()
    resourcesTruncated = false
    samples.removeAll()
    loading = false
    failure = nil
  }

  private static func path(for url: URL) -> String {
    let path = url.path.isEmpty ? "/" : url.path
    guard let query = url.query, !query.isEmpty else { return path }
    return "\(path)?\(query)"
  }
}
