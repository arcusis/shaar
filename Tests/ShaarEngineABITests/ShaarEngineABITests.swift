// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@_cdecl("fake_shaar_abi_major")
private func fakeShaarABIMajor() -> UInt32 { 1 }

@_cdecl("fake_shaar_abi_major_mismatch")
private func fakeShaarABIMajorMismatch() -> UInt32 { 9 }

@_cdecl("fake_shaar_engine_create")
private func fakeShaarEngineCreate() -> Int32 { 0 }

private struct FakeEngine: ShaarSymbolResolving {
  let mismatchedMajor: Bool

  init(mismatchedMajor: Bool = false) { self.mismatchedMajor = mismatchedMajor }

  func symbol(named: String) -> UnsafeRawPointer? {
    switch named {
    case "shaar_abi_major":
      if mismatchedMajor {
        return unsafeBitCast(
          fakeShaarABIMajorMismatch as @convention(c) () -> UInt32, to: UnsafeRawPointer.self)
      }
      return unsafeBitCast(
        fakeShaarABIMajor as @convention(c) () -> UInt32, to: UnsafeRawPointer.self)
    case "shaar_engine_create":
      return unsafeBitCast(
        fakeShaarEngineCreate as @convention(c) () -> Int32, to: UnsafeRawPointer.self)
    default: return nil
    }
  }
}

@Suite("Shaar engine ABI step 0")
struct ShaarEngineABITests {
  @Test func fakeEngineLoadsMatchingMajorAndRequiresBothExports() throws {
    let loader = try ShaarEngineLoader(resolver: FakeEngine())
    #expect(loader.currentMajor() == 1)
    #expect(loader.implementation == .shaar)
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
  }

  @Test func loaderRejectsMismatchedMajorWithTypedError() {
    #expect(throws: ShaarEngineError.unsupportedABI(expected: 1, actual: 9)) {
      try ShaarEngineLoader(resolver: FakeEngine(mismatchedMajor: true))
    }
  }

  @Test func statusCodesMapToTypedSwiftErrors() throws {
    for status in ShaarStatusCode.allCases where status != .ok {
      #expect(throws: ShaarEngineError.status(status, platformCode: 7, message: "diagnostic")) {
        try ShaarStatusCode.decode(status.rawValue, platformCode: 7, message: "diagnostic")
      }
    }
    try ShaarStatusCode.decode(ShaarStatusCode.ok.rawValue)
    #expect(throws: ShaarEngineError.invalidStatusCode(99)) { try ShaarStatusCode.decode(99) }
  }

  @Test @MainActor func eventIsCopiedBeforeMainActorDispatch() async throws {
    var delivered: ShaarCopiedEvent?
    let dispatcher = ShaarEventDispatcher { delivered = $0 }
    let profile = Array("profile".utf8)
    let payload = Array("{\"kind\":\"tab\",\"schemaVersion\":1}".utf8)
    let event = profile.withUnsafeBufferPointer { profileBuffer in
      payload.withUnsafeBufferPointer { payloadBuffer in
        ShaarABIEvent(
          size: UInt32(MemoryLayout<ShaarABIEvent>.size), sequence: 42, kind: 5,
          profileID: ShaarBytes(
            data: profileBuffer.baseAddress.map {
              UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }, size: profile.count),
          sessionID: ShaarBytes(data: nil, size: 0), windowID: ShaarBytes(data: nil, size: 0),
          tabID: ShaarBytes(data: nil, size: 0),
          payloadJSON: ShaarBytes(
            data: payloadBuffer.baseAddress.map {
              UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }, size: payload.count))
      }
    }
    dispatcher.receive(event)
    for _ in 0..<20 where delivered == nil { await Task.yield() }
    #expect(delivered?.sequence == 42)
    #expect(delivered?.profileID == Data(profile))
    #expect(delivered?.payloadJSON == Data(payload))
  }
}

private actor FakeHistoryEngine: ShaarHistorySubmitting {
  struct Call: Sendable {
    let profileID: UUID
    let operation: ShaarHistoryOperation
    let argsJSON: Data
  }
  var reply: Data
  private(set) var calls: [Call] = []

  init(reply: String) { self.reply = Data(reply.utf8) }

  func submitHistory(profileID: UUID, operation: ShaarHistoryOperation, argsJSON: Data) async throws
    -> Data
  {
    calls.append(Call(profileID: profileID, operation: operation, argsJSON: argsJSON))
    return reply
  }

  func setReply(_ value: String) { reply = Data(value.utf8) }
}

@Suite("Shaar history adapter")
struct ShaarHistoryAdapterTests {
  @Test func queryDecodesStrictRowsAndUsesSelectedProfile() async throws {
    let profile = UUID()
    let fake = FakeHistoryEngine(
      reply:
        #"{"schemaVersion":1,"entries":[{"url":"https://example.test/a","title":"A","visitCount":3,"visits":[1700000000123]}]}"#
    )
    let adapter = ShaarHistoryAdapter(engine: fake)
    let entries = try await adapter.query(profileID: profile, maxUrls: 100, maxVisitsPerURL: 1)
    #expect(entries.count == 1)
    #expect(entries[0].visitCount == 3)
    #expect(entries[0].visits == [1_700_000_000_123])
    let calls = await fake.calls
    #expect(calls.first?.profileID == profile)
    #expect(calls.first?.operation == .query)
    let args = try #require(JSONSerialization.jsonObject(with: calls[0].argsJSON) as? [String: Int])
    #expect(args["maxUrls"] == 100)
  }

  @Test func queryRejectsDuplicateURLsAndUnsupportedSchemes() async throws {
    let duplicate =
      #"{"schemaVersion":1,"entries":[{"url":"https://example.test/","title":"A","visitCount":1,"visits":[1]},{"url":"https://example.test/","title":"A","visitCount":1,"visits":[2]}]}"#
    let fake = FakeHistoryEngine(reply: duplicate)
    let adapter = ShaarHistoryAdapter(engine: fake)
    await #expect(
      throws: ShaarHistoryAdapterError.invalidResponse("malformed or duplicate history row")
    ) {
      try await adapter.query(profileID: UUID())
    }
    await fake.setReply(
      #"{"schemaVersion":1,"entries":[{"url":"file:///tmp/a","title":"A","visitCount":1,"visits":[1]}]}"#
    )
    await #expect(
      throws: ShaarHistoryAdapterError.invalidResponse("malformed or duplicate history row")
    ) {
      try await adapter.query(profileID: UUID())
    }
  }

  @Test func insertDeleteWatchAreBoundToExplicitProfile() async throws {
    let profile = UUID()
    let fake = FakeHistoryEngine(
      reply:
        #"{"schemaVersion":1,"accepted":1,"insertedVisits":2,"duplicateVisits":0,"rejected":[]}"#)
    let adapter = ShaarHistoryAdapter(engine: fake)
    let imported = try await adapter.insert(
      profileID: profile, source: "firefox",
      pages: [
        .init(url: "https://import.example/", title: "Imported", visits: [1, 2])
      ])
    #expect(imported.insertedVisits == 2)
    await fake.setReply(#"{"schemaVersion":1,"deleted":1}"#)
    #expect(
      try await adapter.delete(profileID: profile, urls: [URL(string: "https://import.example/")!])
        == 1)
    await fake.setReply(#"{"schemaVersion":1,"subscriptionId":"sub-1"}"#)
    let token = try await adapter.watch(profileID: profile)
    #expect(token == "sub-1")
    await fake.setReply(#"{"schemaVersion":1}"#)
    try await adapter.unwatch(profileID: profile, subscriptionID: token)
    let calls = await fake.calls
    #expect(calls.map(\.operation) == [.insert, .delete, .watch, .unwatch])
    #expect(calls.allSatisfy { $0.profileID == profile })
  }

  @Test func malformedTypedResultsAreRejected() async throws {
    let fake = FakeHistoryEngine(reply: #"{"schemaVersion":1,"deleted":999}"#)
    let adapter = ShaarHistoryAdapter(engine: fake)
    await #expect(throws: ShaarHistoryAdapterError.invalidResponse("invalid delete result")) {
      try await adapter.delete(profileID: UUID(), urls: [URL(string: "https://example.test")!])
    }
  }

  @Test func eventRouterRequiresKnownRegularProfileAndValidHistoryEnvelope() {
    let profile = UUID()
    let id = Data(profile.uuidString.utf8)
    let payload = Data(#"{"schemaVersion":1,"kind":"changed"}"#.utf8)
    let regular = ShaarCopiedEvent(
      sequence: 2, kind: 11, profileID: id, sessionID: Data(),
      windowID: Data(), tabID: Data(), payloadJSON: payload)
    #expect(
      ShaarHistoryEventRouter.changedProfile(for: regular, knownProfiles: [profile]) == profile)
    let privateEvent = ShaarCopiedEvent(
      sequence: 3, kind: 11, profileID: id,
      sessionID: Data("private-session".utf8), windowID: Data(),
      tabID: Data(), payloadJSON: payload)
    #expect(
      ShaarHistoryEventRouter.changedProfile(for: privateEvent, knownProfiles: [profile]) == nil)
    #expect(ShaarHistoryEventRouter.changedProfile(for: regular, knownProfiles: []) == nil)
  }
}
