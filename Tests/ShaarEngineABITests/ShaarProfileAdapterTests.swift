// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import Testing

@testable import ShaarEngineABI

@MainActor private final class FakeProfileEngine: ShaarProfileEngine {
  var nextHandle: UInt64 = 1
  var failNextOpen = false
  var opens: [(String, String)] = []
  var closed: [UInt64] = []
  var deleted: [UInt64] = []
  var activated: [(UInt64, UInt64)] = []

  func openProfile(id: String, relativeDirectory: String) async throws -> UInt64 {
    opens.append((id, relativeDirectory))
    try await Task.sleep(for: .milliseconds(5))
    if failNextOpen {
      failNextOpen = false
      throw ShaarProfileError.native(.notReady)
    }
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
  func storageKeychainProfile(_ handle: UInt64) throws -> ShaarStorageKeychainNativeProfile {
    ShaarStorageKeychainNativeProfile(
      engine: OpaquePointer(bitPattern: 0x44)!,
      scope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size),
        profile: OpaquePointer(bitPattern: Int(handle)), private_session: nil))
  }
}

@Suite("Shaar profile adapter")
struct ShaarProfileAdapterTests {
  @Test @MainActor func shaarDefaultAndFakeOpenDeduplicates() async throws {
    #expect(ShaarEngineImplementation.shippingDefault == .shaar)
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
    #expect(
      try adapter.state(profileID: id, key: "profile.v1.thirdPartyCookiesBlocked")
        == Data("true".utf8))
    try await adapter.delete(profileID: id)
    #expect(fake.deleted == [1])
    #expect(adapter.loadedProfileIDs.isEmpty)
  }

  @Test @MainActor func storageKeychainResolutionUsesOnlyAnOpenProfile() async throws {
    let fake = FakeProfileEngine()
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff07"
    let uuid = try #require(UUID(uuidString: id))
    await #expect(throws: ShaarProfileError.notOpen) {
      try await adapter.resolve(profileID: uuid)
    }

    try await adapter.open(profileID: id)
    let native = try await adapter.resolve(profileID: uuid)
    #expect(native.scope.size == UInt32(MemoryLayout<shaar_scope>.size))
    #expect(native.scope.profile == OpaquePointer(bitPattern: 1))
    #expect(native.scope.private_session == nil)
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

  @Test @MainActor func failedOpenCanBeRetriedWithoutRetainingAStaleRequest() async throws {
    let fake = FakeProfileEngine()
    fake.failNextOpen = true
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff05"

    await #expect(throws: ShaarProfileError.native(.notReady)) {
      try await adapter.open(profileID: id)
    }
    #expect(adapter.loadedProfileIDs.isEmpty)

    try await adapter.open(profileID: id)
    #expect(fake.opens.count == 2)
    #expect(adapter.loadedProfileIDs == [id])
  }

  @Test @MainActor func zeroNativeHandlesAreRejectedForOpenAndCreate() async {
    let fake = FakeProfileEngine()
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    let openedID = "4a4d4885-d38a-4b4a-bc03-b12f634bff09"
    let createdID = "4a4d4885-d38a-4b4a-bc03-b12f634bff10"

    fake.nextHandle = 0
    await #expect(throws: ShaarProfileError.staleHandle) {
      try await adapter.open(profileID: openedID)
    }
    #expect(adapter.loadedProfileIDs.isEmpty)

    fake.nextHandle = 0
    await #expect(throws: ShaarProfileError.staleHandle) {
      try await adapter.create(profileID: createdID, displayName: "Work")
    }
    #expect(adapter.loadedProfileIDs.isEmpty)
  }

  @Test @MainActor func closeReleasesTheOpaqueHandleAndRejectsLaterCalls() async throws {
    let fake = FakeProfileEngine()
    let adapter = ShaarProfileAdapter(engine: fake, implementation: .shaar)
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff06"
    try await adapter.open(profileID: id)

    try adapter.close(profileID: id)
    #expect(fake.closed == [1])
    #expect(adapter.loadedProfileIDs.isEmpty)
    #expect(throws: ShaarProfileError.notOpen) {
      try adapter.activate(profileID: id, inWindow: 77)
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

  @Test @MainActor func malformedProfileDeletionEventDoesNotInvalidateHandle() async throws {
    let fake = FakeProfileEngine()
    var delivered: ShaarCopiedEvent?
    let adapter = ShaarProfileAdapter(
      engine: fake, implementation: .shaar, onProfileEvent: { delivered = $0 })
    let id = "4a4d4885-d38a-4b4a-bc03-b12f634bff08"
    try await adapter.open(profileID: id)
    for (sequence, payload) in [
      (UInt64(9), #"{"kind":"deleted","schemaVersion":2}"#),
      (UInt64(10), #"{"kind":"deleted","schemaVersion":true}"#),
    ] {
      let malformed = ShaarCopiedEvent(
        sequence: sequence, kind: 2, profileID: Data(id.utf8), sessionID: Data(),
        windowID: Data(), tabID: Data(), payloadJSON: Data(payload.utf8))
      adapter.receive(malformed)
      #expect(adapter.loadedProfileIDs == [id])
    }
    let childScopedProfileEvent = ShaarCopiedEvent(
      sequence: 11, kind: 2, profileID: Data(id.utf8), sessionID: Data("private".utf8),
      windowID: Data("window".utf8), tabID: Data("tab".utf8),
      payloadJSON: Data(#"{"kind":"deleted","schemaVersion":1}"#.utf8))
    adapter.receive(childScopedProfileEvent)
    #expect(adapter.loadedProfileIDs == [id])
    #expect(delivered == nil)
  }
}
