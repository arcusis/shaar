import Foundation
import Testing

@testable import ShaarVerification

@Suite struct SwitchProbeMetricsTests {
  @Test func twentySamplesRoundTripSummariesAndAccounting() throws {
    var recorder = SwitchProbeMetricsRecorder()
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(
        iteration: iteration, latencySeconds: Double(iteration) / 1_000,
        residentMemoryBytes: UInt64(iteration * 1_024))
    }

    let report = recorder.report(phase: "initial")
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let latencyJSON = try #require(object["latency"] as? [String: Any])
    let memoryJSON = try #require(object["residentMemory"] as? [String: Any])
    #expect(object["expectedSampleCount"] as? Int == 20)
    #expect((object["samples"] as? [Any])?.count == 20)
    #expect(latencyJSON["count"] as? Int == 20)
    #expect(latencyJSON["p50Milliseconds"] as? Double == 10)
    #expect(latencyJSON["p95Milliseconds"] as? Double == 19)
    #expect(latencyJSON["maxMilliseconds"] as? Double == 20)
    #expect(memoryJSON["count"] as? Int == 20)
    #expect(memoryJSON["p50Bytes"] as? UInt64 == 10_240)
    #expect(memoryJSON["p95Bytes"] as? UInt64 == 19_456)
    #expect(memoryJSON["maxBytes"] as? UInt64 == 20_480)

    let decoded = try JSONDecoder().decode(SwitchProbeMetrics.self, from: data)
    #expect(decoded.phase == "initial")
    #expect(decoded.samples.count == SwitchProbeMetrics.expectedSwitchCount)
    #expect(decoded.latency == report.latency)
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
        iteration: iteration, latencySeconds: Double(iteration), residentMemoryBytes: nil)
    }

    let report = recorder.report(phase: "restart")
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let memoryJSON = try #require(object["residentMemory"] as? [String: Any])
    #expect(object["expectedSampleCount"] as? Int == 20)
    #expect((object["samples"] as? [Any])?.count == 20)
    #expect(memoryJSON["count"] as? Int == 0)
    #expect(memoryJSON["p50Bytes"] is NSNull)
    #expect(memoryJSON["p95Bytes"] is NSNull)
    #expect(memoryJSON["maxBytes"] is NSNull)

    let decoded = try JSONDecoder().decode(SwitchProbeMetrics.self, from: data)
    #expect(decoded.samples.count == SwitchProbeMetrics.expectedSwitchCount)
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
      try recorder.record(iteration: 2, latencySeconds: 0.1, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(iteration: 1, latencySeconds: -0.1, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(iteration: 1, latencySeconds: .infinity, residentMemoryBytes: nil)
    }
    for iteration in 1...SwitchProbeMetrics.expectedSwitchCount {
      try recorder.record(iteration: iteration, latencySeconds: 0, residentMemoryBytes: nil)
    }
    #expect(throws: SwitchProbeMetricsError.self) {
      try recorder.record(iteration: 21, latencySeconds: 0, residentMemoryBytes: nil)
    }
  }
}
