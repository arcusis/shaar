// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarMemorySupport: Equatable {
  case unknown
  case needsEngine
  case ready
}

enum ShaarMemoryEngineGap {
  static func matches(_ message: String) -> Bool {
    if message == "unknown DevTools capability or command" { return true }
    if message == "This DevTools command is unavailable." { return true }
    if message == "DevTools command is not allowed for this capability" { return true }
    // Pinned shaar.20 drops the unknown-command reason and leaves this fallback.
    if message == "DevTools request failed." { return true }
    return false
  }
}

enum ShaarMemoryError: LocalizedError, Equatable {
  case unsupported
  case missingSnapshot

  var errorDescription: String? {
    switch self {
    case .unsupported:
      return "This DevTools command is unavailable."
    case .missingSnapshot:
      return ShellL10n.string("The heap snapshot did not include snapshot data.")
    }
  }
}

enum ShaarMemorySnapshotPayload {
  static func data(from result: [String: Any]) throws -> Data {
    guard let snapshot = result["snapshot"], JSONSerialization.isValidJSONObject(snapshot) else {
      throw ShaarMemoryError.missingSnapshot
    }
    return try JSONSerialization.data(withJSONObject: snapshot)
  }
}

@MainActor protocol ShaarMemoryTransport {
  func takeHeapSnapshot() async throws -> Data
  func startTrackingHeapObjects() async throws
  func stopTrackingHeapObjects() async throws -> Data
}

@MainActor final class ShaarMemoryPendingTransport: ShaarMemoryTransport {
  func takeHeapSnapshot() async throws -> Data {
    throw ShaarMemoryError.unsupported
  }

  func startTrackingHeapObjects() async throws {
    throw ShaarMemoryError.unsupported
  }

  func stopTrackingHeapObjects() async throws -> Data {
    throw ShaarMemoryError.unsupported
  }
}

@MainActor final class ShaarMemoryDeveloperTransport: ShaarMemoryTransport {
  private let developer: DeveloperPageModel

  init(_ developer: DeveloperPageModel) {
    self.developer = developer
  }

  func takeHeapSnapshot() async throws -> Data {
    let result = try await developer.call("HeapProfiler.takeHeapSnapshot")
    return try ShaarMemorySnapshotPayload.data(from: result)
  }

  func startTrackingHeapObjects() async throws {
    _ = try await developer.call(
      "HeapProfiler.startTrackingHeapObjects", params: ["trackAllocations": true])
  }

  func stopTrackingHeapObjects() async throws -> Data {
    let result = try await developer.call("HeapProfiler.stopTrackingHeapObjects")
    return try ShaarMemorySnapshotPayload.data(from: result)
  }
}

@MainActor @Observable
final class ShaarMemoryModel {
  private(set) var support: ShaarMemorySupport = .unknown
  private(set) var snapshot: ShaarHeapSnapshotSummary?
  private(set) var allocations: [ShaarHeapConstructor]?
  private(set) var recording = false
  private(set) var busy = false
  private(set) var failure: String?
  @ObservationIgnored private var transport: any ShaarMemoryTransport
  @ObservationIgnored private var generation = 0

  init(transport: any ShaarMemoryTransport = ShaarMemoryPendingTransport()) {
    self.transport = transport
  }

  func adoptLiveTransport(_ developer: DeveloperPageModel) {
    guard transport is ShaarMemoryPendingTransport else { return }
    transport = ShaarMemoryDeveloperTransport(developer)
  }

  func takeSnapshot() async {
    guard !recording, !busy else { return }
    busy = true
    failure = nil
    generation += 1
    let token = generation
    do {
      let data = try await transport.takeHeapSnapshot()
      guard token == generation else { return }
      snapshot = try ShaarHeapSnapshotReader.summary(from: data)
      support = .ready
      failure = nil
    } catch {
      guard token == generation else { return }
      note(error)
    }
    guard token == generation else { return }
    busy = false
  }

  func toggleRecording() async {
    if recording {
      await stopRecording()
      return
    }
    await startRecording()
  }

  func loadSnapshot(_ data: Data) throws {
    snapshot = try ShaarHeapSnapshotReader.summary(from: data)
    failure = nil
  }

  func loadAllocationProfile(_ data: Data) throws {
    allocations = try ShaarHeapSnapshotReader.allocations(from: data)
    failure = nil
  }

  func reset() {
    generation += 1
    let stopTracking = recording
    snapshot = nil
    allocations = nil
    recording = false
    busy = false
    failure = nil
    support = .unknown
    guard stopTracking else { return }
    let transport = self.transport
    Task { @MainActor in
      try? await transport.stopTrackingHeapObjects()
    }
  }

  private func startRecording() async {
    guard !busy, !recording else { return }
    busy = true
    failure = nil
    generation += 1
    let token = generation
    do {
      try await transport.startTrackingHeapObjects()
      guard token == generation else { return }
      recording = true
      support = .ready
      failure = nil
    } catch {
      guard token == generation else { return }
      note(error)
    }
    guard token == generation else { return }
    busy = false
  }

  private func stopRecording() async {
    guard recording, !busy else { return }
    busy = true
    failure = nil
    generation += 1
    let token = generation
    do {
      let data = try await transport.stopTrackingHeapObjects()
      guard token == generation else { return }
      allocations = try ShaarHeapSnapshotReader.allocations(from: data)
      recording = false
      support = .ready
      failure = nil
    } catch {
      guard token == generation else { return }
      recording = false
      note(error)
    }
    guard token == generation else { return }
    busy = false
  }

  private func note(_ error: Error) {
    let message = error.localizedDescription
    if ShaarMemoryEngineGap.matches(message) {
      support = .needsEngine
      failure = nil
      return
    }
    failure = message
  }
}
