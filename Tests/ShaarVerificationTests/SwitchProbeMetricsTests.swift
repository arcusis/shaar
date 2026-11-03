// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct SwitchProbeMetricsTests {
  @Test func twentySamplesRoundTripSummariesAndAccounting() throws {
    var recorder = SwitchProbeMetricsRecorder()
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(
        kind: .space,
        iteration: iteration, latencySeconds: Double(iteration) / 1_000,
        residentMemoryBytes: UInt64(iteration * 1_024))
      try recorder.record(
        kind: .profile,
        iteration: iteration, latencySeconds: Double(iteration * 2) / 1_000,
        residentMemoryBytes: UInt64(iteration * 2_048))
    }

    let report = recorder.report(phase: "initial")
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let spaceLatencyJSON = try #require(object["spaceSwitchLatency"] as? [String: Any])
    let profileLatencyJSON = try #require(object["profileSwitchLatency"] as? [String: Any])
    let memoryJSON = try #require(object["residentMemory"] as? [String: Any])
    #expect(object["expectedSampleCount"] as? Int == 20)
    #expect(object["latencyBudgetMilliseconds"] as? Double == 150)
    #expect((object["spaceSwitchSamples"] as? [Any])?.count == 20)
    #expect((object["profileSwitchSamples"] as? [Any])?.count == 20)
    #expect(spaceLatencyJSON["count"] as? Int == 20)
    #expect(spaceLatencyJSON["p50Milliseconds"] as? Double == 10)
    #expect(spaceLatencyJSON["p95Milliseconds"] as? Double == 19)
    #expect(spaceLatencyJSON["maxMilliseconds"] as? Double == 20)
    #expect(profileLatencyJSON["p95Milliseconds"] as? Double == 38)
    #expect(object["spaceSwitchWithinBudget"] as? Bool == true)
    #expect(object["profileSwitchWithinBudget"] as? Bool == true)
    #expect(memoryJSON["count"] as? Int == 40)
    #expect(memoryJSON["p50Bytes"] as? UInt64 == 14_336)
    #expect(memoryJSON["p95Bytes"] as? UInt64 == 36_864)
    #expect(memoryJSON["maxBytes"] as? UInt64 == 40_960)

    let decoded = try JSONDecoder().decode(SwitchProbeMetrics.self, from: data)
    #expect(decoded.phase == "initial")
    #expect(decoded.spaceSwitchSamples.count == SwitchProbeMetrics.expectedSwitchCount)
    #expect(decoded.profileSwitchSamples.count == SwitchProbeMetrics.expectedSwitchCount)
    #expect(decoded.spaceSwitchLatency == report.spaceSwitchLatency)
    #expect(decoded.profileSwitchLatency == report.profileSwitchLatency)
    #expect(decoded.residentMemory == report.residentMemory)
    #expect(decoded.measurementScope.contains("Host-plus-IPC"))
    #expect(
      decoded.samples.allSatisfy {
        $0.latencyMilliseconds.isFinite && $0.latencyMilliseconds >= 0
      })
  }

  @Test func missingMemorySamplesRoundTripWithExplicitZeroCount() throws {
    var recorder = SwitchProbeMetricsRecorder()
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(
        kind: .space,
        iteration: iteration, latencySeconds: Double(iteration), residentMemoryBytes: nil)
      try recorder.record(
        kind: .profile,
        iteration: iteration, latencySeconds: Double(iteration), residentMemoryBytes: nil)
    }

    let report = recorder.report(phase: "restart")
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let memoryJSON = try #require(object["residentMemory"] as? [String: Any])
    #expect(object["expectedSampleCount"] as? Int == 20)
    #expect((object["spaceSwitchSamples"] as? [Any])?.count == 20)
    #expect((object["profileSwitchSamples"] as? [Any])?.count == 20)
    #expect(memoryJSON["count"] as? Int == 0)
    #expect(memoryJSON["p50Bytes"] is NSNull)
    #expect(memoryJSON["p95Bytes"] is NSNull)
    #expect(memoryJSON["maxBytes"] is NSNull)

    let decoded = try JSONDecoder().decode(SwitchProbeMetrics.self, from: data)
    #expect(decoded.samples.count == SwitchProbeMetrics.expectedSwitchCount * 2)
    #expect(decoded.residentMemory.count == 0)
    #expect(decoded.residentMemory.p50Bytes == nil)
    #expect(decoded.residentMemory.p95Bytes == nil)
    #expect(decoded.residentMemory.maxBytes == nil)
  }

  @Test func nearestRankPercentilesHandleEmptySingleEvenAndOddSamples() {
    #expect(SwitchProbeMetrics.percentile([Double](), fraction: 0.5) == nil)
    #expect(SwitchProbeMetrics.percentile([7], fraction: 0.5) == 7)
    #expect(SwitchProbeMetrics.percentile([7], fraction: 0.95) == 7)
    #expect(SwitchProbeMetrics.percentile([4, 1, 3, 2], fraction: 0.5) == 2)
    #expect(SwitchProbeMetrics.percentile([4, 1, 3, 2], fraction: 0.95) == 4)
    #expect(SwitchProbeMetrics.percentile([3, 1, 2], fraction: 0.5) == 2)
    #expect(SwitchProbeMetrics.percentile([3, 1, 2], fraction: 0.95) == 3)
    #expect(SwitchProbeMetrics.percentile([1, 2], fraction: .nan) == nil)
  }

  @Test func recorderRejectsInvalidLatencyAndSampleAccounting() throws {
    var recorder = SwitchProbeMetricsRecorder()
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(
        kind: .space, iteration: 2, latencySeconds: 0.1, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(
        kind: .profile, iteration: 1, latencySeconds: -0.1, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(
        kind: .space, iteration: 1, latencySeconds: .infinity, residentMemoryBytes: nil)
    }
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(
        kind: .space, iteration: iteration, latencySeconds: 0, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(
        kind: .space, iteration: 21, latencySeconds: 0, residentMemoryBytes: nil)
    }
  }

  @Test func budgetRequiresCompleteSamplesAndRejectsSlowP95() throws {
    var recorder = SwitchProbeMetricsRecorder()
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(
        kind: .space, iteration: iteration, latencySeconds: 0.149,
        residentMemoryBytes: nil)
      try recorder.record(
        kind: .profile, iteration: iteration, latencySeconds: 0.151,
        residentMemoryBytes: nil)
    }
    let report = recorder.report(phase: "initial")
    #expect(report.spaceSwitchWithinBudget)
    #expect(!report.profileSwitchWithinBudget)

    let incomplete = SwitchProbeMetricsRecorder().report(phase: "restart")
    #expect(!incomplete.spaceSwitchWithinBudget)
    #expect(!incomplete.profileSwitchWithinBudget)
  }
}
