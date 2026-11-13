// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

struct SwitchProbeMetrics: Codable {
  static let expectedSwitchCount = 20
  static let expectedSpaceWarmupTabCount = 2
  static let expectedSpaceWarmupPassCount = 2
  static let expectedSpaceWarmupCount = expectedSpaceWarmupTabCount * expectedSpaceWarmupPassCount
  static let latencyBudgetMilliseconds = 100.0
  static let warmupDiscardReason =
    "The first selections of each same-profile tab can include one-time native WebContents activation and first-display setup. Two complete warm-up passes are measured and reported separately, then excluded from the steady-state Space p95."
  static let measurementScope =
    "Each phase records two complete same-profile Space warm-up passes separately, then 20 measured same-profile Space switches and 20 cross-profile switches. Latency is Host-plus-IPC time from native store selection through native selection acknowledgment; measured p95 must be at most 100 ms. Each sample separately records synchronous store update, native selection acknowledgment, and time to the selected page's next requestAnimationFrame after its displayed-WebContents audit. Authored JavaScript snapshots separately verify account, document, and session continuity and are excluded from latency. Excludes physical display scanout, energy and real accounts. Resident memory measures the main browser process only, excluding renderer, GPU, and other helper processes."

  enum SwitchKind: String, Codable {
    case space
    case profile
  }

  struct Sample: Codable {
    let kind: SwitchKind
    let iteration: Int
    let latencyMilliseconds: Double
    let storeUpdateMilliseconds: Double
    let engineSelectionMilliseconds: Double
    let firstPaintMilliseconds: Double
    let residentMemoryBytes: UInt64?
  }

  struct Summary: Codable, Equatable {
    let count: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maxMilliseconds: Double?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(count, forKey: .count)
      try container.encode(p50Milliseconds, forKey: .p50Milliseconds)
      try container.encode(p95Milliseconds, forKey: .p95Milliseconds)
      try container.encode(maxMilliseconds, forKey: .maxMilliseconds)
    }

    enum CodingKeys: String, CodingKey {
      case count
      case p50Milliseconds
      case p95Milliseconds
      case maxMilliseconds
    }
  }

  struct MemorySummary: Codable, Equatable {
    let count: Int
    let p50Bytes: UInt64?
    let p95Bytes: UInt64?
    let maxBytes: UInt64?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(count, forKey: .count)
      try container.encode(p50Bytes, forKey: .p50Bytes)
      try container.encode(p95Bytes, forKey: .p95Bytes)
      try container.encode(maxBytes, forKey: .maxBytes)
    }

    enum CodingKeys: String, CodingKey {
      case count
      case p50Bytes
      case p95Bytes
      case maxBytes
    }
  }

  let schema = 5
  let phase: String
  let measurementScope = Self.measurementScope
  let expectedSampleCount = Self.expectedSwitchCount
  let latencyBudgetMilliseconds = Self.latencyBudgetMilliseconds
  let expectedSpaceWarmupCount = Self.expectedSpaceWarmupCount
  let warmupDiscardReason = Self.warmupDiscardReason
  let spaceWarmupSamples: [Sample]
  let spaceSwitchSamples: [Sample]
  let profileSwitchSamples: [Sample]
  var samples: [Sample] { spaceSwitchSamples + profileSwitchSamples }

  var spaceSwitchLatency: Summary { latency(for: spaceSwitchSamples) }
  var profileSwitchLatency: Summary { latency(for: profileSwitchSamples) }

  func latencyDiagnostic(for kind: SwitchKind) -> String {
    let samples = kind == .space ? spaceSwitchSamples : profileSwitchSamples
    guard let slowest = samples.max(by: { $0.latencyMilliseconds < $1.latencyMilliseconds }) else {
      return "no \(kind.rawValue) switch samples"
    }
    let summary = kind == .space ? spaceSwitchLatency : profileSwitchLatency
    return String(
      format:
        "p95 %.1f ms; slowest sample %d %.1f ms (store update %.1f ms, native selection %.1f ms, next paint %.1f ms)",
      summary.p95Milliseconds ?? .infinity, slowest.iteration, slowest.latencyMilliseconds,
      slowest.storeUpdateMilliseconds, slowest.engineSelectionMilliseconds,
      slowest.firstPaintMilliseconds)
  }

  static func spaceWarmupSequence(tabIDs: [String], selectedTabID: String?) -> [String]? {
    guard tabIDs.count == expectedSpaceWarmupTabCount,
      Set(tabIDs).count == expectedSpaceWarmupTabCount
    else { return nil }
    let orderedTabIDs =
      tabIDs.filter { $0 != selectedTabID }
      + tabIDs.filter { $0 == selectedTabID }
    return (0..<expectedSpaceWarmupPassCount).flatMap { _ in orderedTabIDs }
  }

  var spaceSwitchWithinBudget: Bool {
    spaceWarmupSamples.count == Self.expectedSpaceWarmupCount
      && spaceSwitchSamples.count == Self.expectedSwitchCount
      && (spaceSwitchLatency.p95Milliseconds ?? .infinity) <= Self.latencyBudgetMilliseconds
  }

  var profileSwitchWithinBudget: Bool {
    profileSwitchSamples.count == Self.expectedSwitchCount
      && (profileSwitchLatency.p95Milliseconds ?? .infinity) <= Self.latencyBudgetMilliseconds
  }

  private func latency(for samples: [Sample]) -> Summary {
    let values = samples.map(\.latencyMilliseconds)
    return Summary(
      count: values.count,
      p50Milliseconds: Self.percentile(values, fraction: 0.50),
      p95Milliseconds: Self.percentile(values, fraction: 0.95),
      maxMilliseconds: values.max())
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case phase
    case measurementScope
    case expectedSampleCount
    case latencyBudgetMilliseconds
    case expectedSpaceWarmupCount
    case warmupDiscardReason
    case spaceWarmupSamples
    case spaceSwitchSamples
    case profileSwitchSamples
    case spaceSwitchLatency
    case profileSwitchLatency
    case spaceSwitchWithinBudget
    case profileSwitchWithinBudget
    case residentMemory
  }

  init(
    phase: String, spaceWarmupSamples: [Sample], spaceSwitchSamples: [Sample],
    profileSwitchSamples: [Sample]
  ) {
    self.phase = phase
    self.spaceWarmupSamples = spaceWarmupSamples
    self.spaceSwitchSamples = spaceSwitchSamples
    self.profileSwitchSamples = profileSwitchSamples
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    phase = try container.decode(String.self, forKey: .phase)
    spaceWarmupSamples = try container.decode([Sample].self, forKey: .spaceWarmupSamples)
    spaceSwitchSamples = try container.decode([Sample].self, forKey: .spaceSwitchSamples)
    profileSwitchSamples = try container.decode([Sample].self, forKey: .profileSwitchSamples)
    guard try container.decode(Int.self, forKey: .schema) == schema,
      try container.decode(String.self, forKey: .measurementScope) == Self.measurementScope,
      try container.decode(Int.self, forKey: .expectedSampleCount) == Self.expectedSwitchCount,
      try container.decode(Double.self, forKey: .latencyBudgetMilliseconds)
        == Self.latencyBudgetMilliseconds,
      try container.decode(Int.self, forKey: .expectedSpaceWarmupCount)
        == Self.expectedSpaceWarmupCount,
      try container.decode(String.self, forKey: .warmupDiscardReason) == Self.warmupDiscardReason
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schema, in: container, debugDescription: "Invalid switch metrics metadata.")
    }
    guard try container.decode(Summary.self, forKey: .spaceSwitchLatency) == spaceSwitchLatency,
      try container.decode(Summary.self, forKey: .profileSwitchLatency) == profileSwitchLatency,
      try container.decode(Bool.self, forKey: .spaceSwitchWithinBudget) == spaceSwitchWithinBudget,
      try container.decode(Bool.self, forKey: .profileSwitchWithinBudget)
        == profileSwitchWithinBudget,
      try container.decode(MemorySummary.self, forKey: .residentMemory) == residentMemory
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .spaceSwitchLatency, in: container,
        debugDescription: "Switch metrics summaries do not match samples.")
    }
    guard valid(spaceWarmupSamples, kind: .space, count: Self.expectedSpaceWarmupCount),
      valid(spaceSwitchSamples, kind: .space, count: Self.expectedSwitchCount),
      valid(profileSwitchSamples, kind: .profile, count: Self.expectedSwitchCount)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .spaceSwitchSamples, in: container, debugDescription: "Invalid switch samples.")
    }
  }

  private func valid(_ samples: [Sample], kind: SwitchKind, count: Int) -> Bool {
    samples.count == count
      && samples.enumerated().allSatisfy({ index, sample in
        sample.iteration == index + 1 && sample.latencyMilliseconds.isFinite
          && sample.latencyMilliseconds >= 0 && sample.kind == kind
          && [
            sample.storeUpdateMilliseconds, sample.engineSelectionMilliseconds,
            sample.firstPaintMilliseconds,
          ].allSatisfy { $0.isFinite && $0 >= 0 && ($0 * 1_000).isFinite }
      })
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(phase, forKey: .phase)
    try container.encode(measurementScope, forKey: .measurementScope)
    try container.encode(expectedSampleCount, forKey: .expectedSampleCount)
    try container.encode(latencyBudgetMilliseconds, forKey: .latencyBudgetMilliseconds)
    try container.encode(expectedSpaceWarmupCount, forKey: .expectedSpaceWarmupCount)
    try container.encode(warmupDiscardReason, forKey: .warmupDiscardReason)
    try container.encode(spaceWarmupSamples, forKey: .spaceWarmupSamples)
    try container.encode(spaceSwitchSamples, forKey: .spaceSwitchSamples)
    try container.encode(profileSwitchSamples, forKey: .profileSwitchSamples)
    try container.encode(spaceSwitchLatency, forKey: .spaceSwitchLatency)
    try container.encode(profileSwitchLatency, forKey: .profileSwitchLatency)
    try container.encode(spaceSwitchWithinBudget, forKey: .spaceSwitchWithinBudget)
    try container.encode(profileSwitchWithinBudget, forKey: .profileSwitchWithinBudget)
    try container.encode(residentMemory, forKey: .residentMemory)
  }

  var residentMemory: MemorySummary {
    let values = samples.compactMap(\.residentMemoryBytes).sorted()
    return MemorySummary(
      count: values.count,
      p50Bytes: Self.percentile(values, fraction: 0.50),
      p95Bytes: Self.percentile(values, fraction: 0.95),
      maxBytes: values.max())
  }

  static func percentile<T: Comparable>(_ values: [T], fraction: Double) -> T? {
    guard !values.isEmpty, fraction.isFinite, (0...1).contains(fraction) else { return nil }
    let sorted = values.sorted()
    let index = max(0, Int(ceil(fraction * Double(sorted.count))) - 1)
    return sorted[index]
  }
}

struct SwitchProbeMetricsRecorder {
  private(set) var spaceWarmupSamples: [SwitchProbeMetrics.Sample] = []
  private(set) var spaceSwitchSamples: [SwitchProbeMetrics.Sample] = []
  private(set) var profileSwitchSamples: [SwitchProbeMetrics.Sample] = []

  mutating func recordSpaceWarmup(
    iteration: Int, latencySeconds: Double, storeUpdateSeconds: Double = 0,
    engineSelectionSeconds: Double = 0, firstPaintSeconds: Double = 0,
    residentMemoryBytes: UInt64?
  ) throws {
    let latencyMilliseconds = latencySeconds * 1_000
    let validBreakdown = [storeUpdateSeconds, engineSelectionSeconds, firstPaintSeconds]
      .allSatisfy { $0.isFinite && $0 >= 0 && ($0 * 1_000).isFinite }
    guard iteration == spaceWarmupSamples.count + 1,
      iteration <= SwitchProbeMetrics.expectedSpaceWarmupCount,
      latencySeconds.isFinite, latencySeconds >= 0, latencyMilliseconds.isFinite,
      validBreakdown
    else { throw SwitchProbeMetricsError.invalidSample }
    spaceWarmupSamples.append(
      SwitchProbeMetrics.Sample(
        kind: .space, iteration: iteration, latencyMilliseconds: latencyMilliseconds,
        storeUpdateMilliseconds: storeUpdateSeconds * 1_000,
        engineSelectionMilliseconds: engineSelectionSeconds * 1_000,
        firstPaintMilliseconds: firstPaintSeconds * 1_000,
        residentMemoryBytes: residentMemoryBytes))
  }

  mutating func record(
    kind: SwitchProbeMetrics.SwitchKind, iteration: Int, latencySeconds: Double,
    storeUpdateSeconds: Double = 0, engineSelectionSeconds: Double = 0,
    firstPaintSeconds: Double = 0,
    residentMemoryBytes: UInt64?
  ) throws {
    let latencyMilliseconds = latencySeconds * 1_000
    let count = kind == .space ? spaceSwitchSamples.count : profileSwitchSamples.count
    let validBreakdown = [storeUpdateSeconds, engineSelectionSeconds, firstPaintSeconds]
      .allSatisfy { $0.isFinite && $0 >= 0 && ($0 * 1_000).isFinite }
    guard iteration == count + 1,
      iteration <= SwitchProbeMetrics.expectedSwitchCount,
      latencySeconds.isFinite, latencySeconds >= 0, latencyMilliseconds.isFinite,
      validBreakdown
    else { throw SwitchProbeMetricsError.invalidSample }
    let sample = SwitchProbeMetrics.Sample(
      kind: kind,
      iteration: iteration,
      latencyMilliseconds: latencyMilliseconds,
      storeUpdateMilliseconds: storeUpdateSeconds * 1_000,
      engineSelectionMilliseconds: engineSelectionSeconds * 1_000,
      firstPaintMilliseconds: firstPaintSeconds * 1_000,
      residentMemoryBytes: residentMemoryBytes)
    if kind == .space {
      spaceSwitchSamples.append(sample)
    } else {
      profileSwitchSamples.append(sample)
    }
  }

  func report(phase: String) -> SwitchProbeMetrics {
    SwitchProbeMetrics(
      phase: phase, spaceWarmupSamples: spaceWarmupSamples,
      spaceSwitchSamples: spaceSwitchSamples,
      profileSwitchSamples: profileSwitchSamples)
  }
}

enum SwitchProbeMetricsError: Error {
  case invalidSample
}

enum NativeResidentMemory {
  static func currentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, info.resident_size > 0 else { return nil }
    return UInt64(info.resident_size)
  }
}
