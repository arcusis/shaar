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

@MainActor private final class FakeProfileEngine: ShaarProfileEngine {
  var nextHandle: UInt64 = 1
  var opens: [(String, String)] = []
  var closed: [UInt64] = []
  var deleted: [UInt64] = []
  var activated: [(UInt64, UInt64)] = []

  func openProfile(id: String, relativeDirectory: String) async throws -> UInt64 {
    opens.append((id, relativeDirectory))
    try await Task.sleep(for: .milliseconds(5))
    defer { nextHandle += 1 }
    return nextHandle
  }

  func createProfile(id: String, displayName: String) async throws -> UInt64 {
    defer { nextHandle += 1 }
    return nextHandle
  }

  func closeProfile(_ handle: UInt64) throws { closed.append(handle) }
  func deleteProfile(_ handle: UInt64) async throws { deleted.append(handle) }
  func activateProfile(_ handle: UInt64, inWindow window: UInt64) throws {
    activated.append((handle, window))
  }
  func getProfileState(_ handle: UInt64, key: String) throws -> Data { Data("true".utf8) }
  func setProfileState(_ handle: UInt64, key: String, valueJSON: Data) throws {}
  func profilePath(_ handle: UInt64) throws -> Data { Data("/fake/Profile".utf8) }
}

@Suite("Shaar profile adapter")
struct ShaarProfileAdapterTests {
  @Test @MainActor func defaultRemainsArdiaAndFakeOpenDeduplicates() async throws {
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    let fake = FakeProfileEngine()
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    async let first: Void = adapter.open(profileID: "4a4d4885-d38a-4b4a-bc03-b12f634bff01")
    async let second: Void = adapter.open(profileID: "4a4d4885-d38a-4b4a-bc03-b12f634bff01")
    _ = try await (first, second)
    #expect(fake.opens.count == 1)
    #expect(fake.opens.first?.1 == "Profile 4a4d4885-d38a-4b4a-bc03-b12f634bff01")
    #expect(adapter.loadedProfileIDs == ["4a4d4885-d38a-4b4a-bc03-b12f634bff01"])
  }

  @Test @MainActor func lifecycleCallsStayScopedToOpaqueHandle() async throws {
    let fake = FakeProfileEngine()
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff02"
    try await adapter.create(profileID: id, displayName: "Work")
    try adapter.activate(profileID: id, inWindow: 77)
    #expect(fake.activated.count == 1)
    #expect(fake.activated[0].0 == 1 && fake.activated[0].1 == 77)
    #expect(try adapter.state(profileID: id, key: "profile.v1.thirdPartyCookiesBlocked") == Data("true".utf8))
    try await adapter.delete(profileID: id)
    #expect(fake.deleted == [1])
    #expect(adapter.loadedProfileIDs.isEmpty)
  }

  @Test @MainActor func malformedAndNoncanonicalUUIDsAreRejected() async {
    let adapter = ShaarProfileAdapter(engine: FakeProfileEngine(), implementation: .shaar)
    await #expect(throws: ShaarProfileError.invalidIdentifier) {
      try await adapter.open(profileID: "../Default")
    }
    await #expect(throws: ShaarProfileError.invalidIdentifier) {
      try await adapter.open(profileID: "4A4D4885-D38A-4B4A-BC03-B12F634BFF03")
    }
  }

  @Test @MainActor func copiedProfileEventsRouteAndInvalidateClosedHandles() async throws {
    let fake = FakeProfileEngine()
    var delivered: ShaarCopiedEvent?
    let adapter = ShaarProfileAdapter(
      engine: fake, implementation: .shaar, onProfileEvent: { delivered = $0 })
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff04"
    try await adapter.open(profileID: id)
    let event = ShaarCopiedEvent(
      sequence: 8, kind: 2, profileID: Data(id.utf8), sessionID: Data(),
      windowID: Data(), tabID: Data(),
      payloadJSON: Data("{\"kind\":\"deleted\",\"schemaVersion\":1}".utf8))
    adapter.receive(event)
    #expect(delivered == event)
    #expect(adapter.loadedProfileIDs.isEmpty)
  }
}
