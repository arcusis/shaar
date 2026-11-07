// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarMemoryModelTests {
  @Test func fixtureSnapshotSummarizesConstructorsBySize() throws {
    let summary = try ShaarHeapSnapshotReader.summary(from: ShaarMemoryFixture.snapshotData())
    #expect(summary.totalBytes == 4800)
    #expect(summary.nodeCount == 5)
    #expect(summary.constructors.map(\.name) == ["Window", "HTMLDivElement", "Array", "(string)"])
    #expect(summary.constructors.map(\.selfBytes) == [2000, 1500, 1200, 100])
    #expect(summary.constructors.map(\.count) == [1, 1, 2, 1])
    #expect(throws: ShaarHeapSnapshotError.self) {
      try ShaarHeapSnapshotReader.allocations(from: ShaarMemoryFixture.snapshotData())
    }
  }

  @Test func fixtureAllocationProfileKeepsNodesAllocatedAfterTheBaseline() throws {
    let allocated = try ShaarHeapSnapshotReader.allocations(
      from: ShaarMemoryFixture.allocationProfileData())
    #expect(allocated.map(\.name) == ["HTMLDivElement", "Array", "(string)"])
    #expect(allocated.map(\.selfBytes) == [1500, 400, 100])
    #expect(allocated.map(\.count) == [1, 1, 1])
  }

  @Test func stringNodesAndEmptyNamesCollapseAndEqualSizesSortByName() throws {
    let data = try snapshotData(
      types: ["object", "string", "concatenated string", "sliced string"],
      strings: ["", "Beta", "Alpha"],
      nodes: [
        0, 2, 1, 10, 0,
        0, 1, 2, 10, 0,
        1, 1, 3, 4, 0,
        2, 0, 4, 1, 0,
        3, 0, 5, 1, 0,
      ],
      nodeCount: 5)
    let summary = try ShaarHeapSnapshotReader.summary(from: data)
    #expect(summary.constructors.map(\.name) == ["Alpha", "Beta", "(string)"])
    #expect(summary.constructors[0].selfBytes == 10)
    #expect(summary.constructors[1].selfBytes == 10)
    #expect(summary.constructors[2].selfBytes == 6)
    #expect(summary.constructors[2].count == 3)
  }

  @Test func nodeCountInMetaIsAccepted() throws {
    let data = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [0, 1, 1, 20, 0], nodeCount: 1,
      countInMeta: true)
    let summary = try ShaarHeapSnapshotReader.summary(from: data)
    #expect(summary.nodeCount == 1)
    #expect(summary.totalBytes == 20)
  }

  @Test func malformedSnapshotsFailClosed() throws {
    let mismatch = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [0, 1, 1, 20, 0], nodeCount: 2)
    expectMalformed("The heap snapshot node count does not match.") {
      _ = try ShaarHeapSnapshotReader.summary(from: mismatch)
    }
    let negative = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [0, 1, 1, -5, 0], nodeCount: 1)
    expectMalformed("The heap snapshot contains a negative size.") {
      _ = try ShaarHeapSnapshotReader.summary(from: negative)
    }
    let fraction = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [0, 1, 1, 1.5, 0], nodeCount: 1)
    expectMalformed("The heap snapshot node values are invalid.") {
      _ = try ShaarHeapSnapshotReader.summary(from: fraction)
    }
    let huge = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [], nodeCount: 2_000_001)
    expectMalformed("The heap snapshot is too large.") {
      _ = try ShaarHeapSnapshotReader.summary(from: huge)
    }
    expectMalformed("The allocation profile has no samples.") {
      _ = try ShaarHeapSnapshotReader.allocations(from: ShaarMemoryFixture.snapshotData())
    }
  }

  @Test func nothingAllocatedIsAnEmptyProfile() throws {
    let data = try snapshotData(
      types: ["object"], strings: ["", "Window"], nodes: [0, 1, 1, 20, 0], nodeCount: 1,
      samples: [0, 9])
    let allocated = try ShaarHeapSnapshotReader.allocations(from: data)
    #expect(allocated.isEmpty)
  }

  @Test func byteTotalsRejectOverflowAndFormatSizes() throws {
    #expect(throws: ShaarHeapSnapshotError.malformed("The heap snapshot size overflowed.")) {
      _ = try ShaarHeapByteTotal.add(1, to: Int64.max)
    }
    #expect(throws: ShaarHeapSnapshotError.malformed("The heap snapshot contains a negative size."))
    {
      _ = try ShaarHeapByteTotal.add(-1, to: 4)
    }
    #expect(ShaarByteCount.format(100) == "100 B")
    #expect(ShaarByteCount.format(4800) == "4.7 KB")
    #expect(ShaarByteCount.format(1_500_000) == "1.4 MB")
  }

  @Test func engineGapIsTheUnavailableCommandNotAClosedTarget() {
    #expect(ShaarMemoryEngineGap.matches("unknown DevTools capability or command"))
    #expect(ShaarMemoryEngineGap.matches("This DevTools command is unavailable."))
    #expect(ShaarMemoryEngineGap.matches("DevTools command is not allowed for this capability"))
    #expect(ShaarMemoryEngineGap.matches("DevTools request failed."))
    #expect(!ShaarMemoryEngineGap.matches("The developer tools target is no longer available."))
    #expect(!ShaarMemoryEngineGap.matches("Shaar DevTools is unavailable."))
    #expect(!ShaarMemoryEngineGap.matches("DevTools returned an invalid reply."))
  }

  @Test func pendingTransportGatesAndFixtureLoadsKeepSupport() async throws {
    let model = ShaarMemoryModel()
    await model.takeSnapshot()
    #expect(model.support == .needsEngine)
    #expect(model.snapshot == nil)
    #expect(model.failure == nil)
    try model.loadSnapshot(ShaarMemoryFixture.snapshotData())
    try model.loadAllocationProfile(ShaarMemoryFixture.allocationProfileData())
    #expect(model.support == .needsEngine)
    #expect(model.snapshot?.totalBytes == 4800)
    #expect(model.allocations?.first?.name == "HTMLDivElement")
  }

  @Test func recordingListsAllocatedConstructorsAndBlocksSnapshots() async throws {
    let transport = ScriptedMemoryTransport()
    let model = ShaarMemoryModel(transport: transport)
    await model.toggleRecording()
    #expect(model.recording)
    #expect(model.support == .ready)
    #expect(transport.started == 1)
    await model.takeSnapshot()
    #expect(model.snapshot == nil)
    await model.toggleRecording()
    #expect(!model.recording)
    #expect(transport.stopped == 1)
    #expect(model.allocations?.map(\.name) == ["HTMLDivElement", "Array", "(string)"])
  }

  @Test func closedTargetStaysAFailure() async {
    let transport = ScriptedMemoryTransport()
    transport.snapshotError = TargetClosed()
    let model = ShaarMemoryModel(transport: transport)
    await model.takeSnapshot()
    #expect(model.support == .unknown)
    #expect(model.failure == "The developer tools target is no longer available.")
  }

  @Test func missingSnapshotDataIsAFailure() async {
    let transport = ScriptedMemoryTransport()
    transport.snapshot = Data("{}".utf8)
    let model = ShaarMemoryModel(transport: transport)
    await model.takeSnapshot()
    #expect(model.support == .unknown)
    #expect(model.failure == "The heap snapshot is invalid.")
    #expect(throws: ShaarMemoryError.missingSnapshot) {
      try ShaarMemorySnapshotPayload.data(from: [:])
    }
    #expect(
      BrowserLocalization.string(
        "Memory", table: "Shell", language: .hebrew) == "זיכרון")
    #expect(
      BrowserLocalization.string(
        "Live heap snapshots need engine support", table: "Shell", language: .hebrew)
        == "צילומי ערימה חיים זקוקים לתמיכת המנוע")
  }

  @Test func resetDropsASnapshotThatFinishesLate() async {
    let transport = PausingMemoryTransport()
    let model = ShaarMemoryModel(transport: transport)
    let task = Task { await model.takeSnapshot() }
    var attempts = 0
    while !transport.started && attempts < 50 {
      await Task.yield()
      attempts += 1
    }
    #expect(transport.started)
    model.reset()
    transport.release()
    await task.value
    #expect(model.snapshot == nil)
    #expect(model.busy == false)
    #expect(model.support == .unknown)
  }

  @Test func resetStopsAnActiveRecording() async {
    let transport = ScriptedMemoryTransport()
    let model = ShaarMemoryModel(transport: transport)
    await model.toggleRecording()
    model.reset()
    var attempts = 0
    while transport.stopped == 0 && attempts < 50 {
      await Task.yield()
      attempts += 1
    }
    #expect(transport.stopped == 1)
    #expect(model.recording == false)
    #expect(model.snapshot == nil)
  }

  @Test func memoryPanelRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    let waiting = ShaarMemoryModel()
    let emptyWide = try renderMemory(waiting, width: 640, height: 480)
    let emptyNarrow = try renderMemory(waiting, width: 220, height: 520)
    await waiting.takeSnapshot()
    #expect(waiting.support == .needsEngine)
    let gated = try renderMemory(waiting, width: 640, height: 420)

    let paused = PausingMemoryTransport()
    let busyModel = ShaarMemoryModel(transport: paused)
    let task = Task { await busyModel.takeSnapshot() }
    var attempts = 0
    while !paused.started && attempts < 50 {
      await Task.yield()
      attempts += 1
    }
    #expect(busyModel.busy)
    let busy = try renderMemory(busyModel, width: 640, height: 420)
    paused.release()
    await task.value

    let failedTransport = ScriptedMemoryTransport()
    failedTransport.snapshotError = TargetClosed()
    let failedModel = ShaarMemoryModel(transport: failedTransport)
    await failedModel.takeSnapshot()
    #expect(failedModel.failure == "The developer tools target is no longer available.")
    let failed = try renderMemory(failedModel, width: 640, height: 420)

    let recordingTransport = ScriptedMemoryTransport()
    let recordingModel = ShaarMemoryModel(transport: recordingTransport)
    await recordingModel.toggleRecording()
    #expect(recordingModel.recording)
    let recording = try renderMemory(recordingModel, width: 640, height: 420)

    let populated = ShaarMemoryModel()
    try populated.loadSnapshot(ShaarMemoryFixture.snapshotData())
    try populated.loadAllocationProfile(ShaarMemoryFixture.allocationProfileData())
    #expect(populated.snapshot?.constructors.isEmpty == false)
    let rows = try renderMemory(populated, width: 640, height: 560)

    let defaults = UserDefaults(suiteName: "ShaarMemory.render.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .memory
    await shell.memory.takeSnapshot()
    #expect(shell.memory.support == .needsEngine)
    let shellGated = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    try shell.memory.loadSnapshot(ShaarMemoryFixture.snapshotData())
    try shell.memory.loadAllocationProfile(ShaarMemoryFixture.allocationProfileData())
    let shellRows = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!emptyWide.isEmpty)
    #expect(!emptyNarrow.isEmpty)
    #expect(!gated.isEmpty)
    #expect(!busy.isEmpty)
    #expect(!failed.isEmpty)
    #expect(!recording.isEmpty)
    #expect(!rows.isEmpty)
    #expect(!shellGated.isEmpty)
    #expect(!shellRows.isEmpty)
    shell.close()
  }
}

@MainActor private func renderMemory(
  _ model: ShaarMemoryModel, width: CGFloat, height: CGFloat
) throws -> Data {
  try VisualCapture.pngOffscreen(
    ShaarMemoryPanel(model: model), size: NSSize(width: width, height: height))
}

@MainActor private final class ScriptedMemoryTransport: ShaarMemoryTransport {
  var snapshot = ShaarMemoryFixture.snapshotData()
  var allocation = ShaarMemoryFixture.allocationProfileData()
  var snapshotError: Error?
  var started = 0
  var stopped = 0

  func takeHeapSnapshot() async throws -> Data {
    if let snapshotError { throw snapshotError }
    return snapshot
  }

  func startTrackingHeapObjects() async throws {
    started += 1
  }

  func stopTrackingHeapObjects() async throws -> Data {
    stopped += 1
    return allocation
  }
}

@MainActor private final class PausingMemoryTransport: ShaarMemoryTransport {
  private(set) var started = false
  private var released = false

  func takeHeapSnapshot() async throws -> Data {
    started = true
    while !released {
      await Task.yield()
    }
    return ShaarMemoryFixture.snapshotData()
  }

  func startTrackingHeapObjects() async throws {}

  func stopTrackingHeapObjects() async throws -> Data { Data() }

  func release() { released = true }
}

private struct TargetClosed: LocalizedError {
  var errorDescription: String? { "The developer tools target is no longer available." }
}

private func expectMalformed(_ message: String, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("expected \(message)")
  } catch let error as ShaarHeapSnapshotError {
    #expect(error == .malformed(message))
  } catch {
    Issue.record("unexpected error \(error)")
  }
}

private func snapshotData(
  types: [String], strings: [String], nodes: [Any], nodeCount: Int,
  samples: [Int]? = nil, countInMeta: Bool = false
) throws -> Data {
  var meta: [String: Any] = [
    "node_fields": ["type", "name", "id", "self_size", "edge_count"],
    "node_types": [types],
    "sample_fields": ["timestamp_us", "last_assigned_id"],
  ]
  var snapshot: [String: Any] = ["meta": meta]
  if countInMeta {
    meta["node_count"] = nodeCount
    snapshot["meta"] = meta
  } else {
    snapshot["node_count"] = nodeCount
  }
  var root: [String: Any] = ["snapshot": snapshot, "nodes": nodes, "strings": strings]
  if let samples { root["samples"] = samples }
  return try JSONSerialization.data(withJSONObject: root)
}
