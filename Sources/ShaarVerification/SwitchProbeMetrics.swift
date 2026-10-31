import Darwin
import Foundation

struct SwitchProbeMetrics: Codable {
  static let expectedSwitchCount = 20
  static let measurementScope =
    "Host-plus-IPC time from native store selection through verified authored JavaScript snapshot completion; excludes physical paint, energy, and real account acceptance. Resident memory measures the main browser process only, excluding renderer, GPU, and other helper processes."

  struct Sample: Codable {
    let iteration: Int
    let latencyMilliseconds: Double
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

  let schema = 1
  let phase: String
  let measurementScope = Self.measurementScope
  let expectedSampleCount = Self.expectedSwitchCount
  let samples: [Sample]

  var latency: Summary {
    let values = samples.map(\.latencyMilliseconds)
    return Summary(
      count: values.count,
      p50Milliseconds: Self.percentile(values, fraction: 0.50),
      p95Milliseconds: Self.percentile(values, fraction: 0.95),
      maxMilliseconds: values.max())
  }

  var residentMemory: MemorySummary {
    let values = samples.compactMap(\.residentMemoryBytes).sorted()
    return MemorySummary(
      count: values.count,
      p50Bytes: Self.percentile(values, fraction: 0.50),
      p95Bytes: Self.percentile(values, fraction: 0.95),
      maxBytes: values.max())
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case phase
    case measurementScope
    case expectedSampleCount
    case samples
    case latency
    case residentMemory
  }

  init(phase: String, samples: [Sample]) {
    self.phase = phase
    self.samples = samples
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    phase = try container.decode(String.self, forKey: .phase)
    samples = try container.decode([Sample].self, forKey: .samples)
    guard try container.decode(Int.self, forKey: .schema) == schema,
      try container.decode(String.self, forKey: .measurementScope) == Self.measurementScope,
      try container.decode(Int.self, forKey: .expectedSampleCount) == Self.expectedSwitchCount
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schema, in: container, debugDescription: "Invalid switch metrics metadata.")
    }
    guard try container.decode(Summary.self, forKey: .latency) == latency,
      try container.decode(MemorySummary.self, forKey: .residentMemory) == residentMemory
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .latency, in: container,
        debugDescription: "Switch metrics summaries do not match samples.")
    }
    guard samples.count <= Self.expectedSwitchCount,
      samples.enumerated().allSatisfy({ index, sample in
        sample.iteration == index + 1 && sample.latencyMilliseconds.isFinite
          && sample.latencyMilliseconds >= 0
      })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .samples, in: container, debugDescription: "Invalid switch samples.")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(phase, forKey: .phase)
    try container.encode(measurementScope, forKey: .measurementScope)
    try container.encode(expectedSampleCount, forKey: .expectedSampleCount)
    try container.encode(samples, forKey: .samples)
    try container.encode(latency, forKey: .latency)
    try container.encode(residentMemory, forKey: .residentMemory)
  }

  static func percentile<T: Comparable>(_ values: [T], fraction: Double) -> T? {
    guard !values.isEmpty, fraction.isFinite, (0...1).contains(fraction) else { return nil }
    let sorted = values.sorted()
    let index = max(0, Int(ceil(fraction * Double(sorted.count))) - 1)
    return sorted[index]
  }
}

struct SwitchProbeMetricsRecorder {
  private(set) var samples: [SwitchProbeMetrics.Sample] = []

  mutating func record(
    iteration: Int, latencySeconds: Double, residentMemoryBytes: UInt64?
  ) throws {
    let latencyMilliseconds = latencySeconds * 1_000
    guard iteration == samples.count + 1,
      iteration <= SwitchProbeMetrics.expectedSwitchCount,
      latencySeconds.isFinite, latencySeconds >= 0, latencyMilliseconds.isFinite
    else { throw SwitchProbeMetricsError.invalidSample }
    samples.append(
      .init(
        iteration: iteration,
        latencyMilliseconds: latencyMilliseconds,
        residentMemoryBytes: residentMemoryBytes))
  }

  func report(phase: String) -> SwitchProbeMetrics {
    SwitchProbeMetrics(phase: phase, samples: samples)
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
