// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineC
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

  @Test func swiftEventTypesUseTheImportedCLayouts() {
    #expect(MemoryLayout<ShaarBytes>.size == MemoryLayout<shaar_bytes>.size)
    #expect(MemoryLayout<ShaarABIEvent>.size == MemoryLayout<shaar_event>.size)
    #expect(MemoryLayout<ShaarABIEvent>.alignment == MemoryLayout<shaar_event>.alignment)
  }

  @Test @MainActor func eventIsCopiedBeforeMainActorDispatch() async throws {
    var delivered: ShaarCopiedEvent?
    let dispatcher = ShaarEventDispatcher { delivered = $0 }
    let profile = Array("profile".utf8)
    let payload = Array("{\"kind\":\"tab\",\"schemaVersion\":1}".utf8)
    profile.withUnsafeBufferPointer { profileBuffer in
      payload.withUnsafeBufferPointer { payloadBuffer in
        var event = shaar_event()
        event.size = UInt32(MemoryLayout<shaar_event>.size)
        event.sequence = 42
        event.kind = shaar_event_kind(rawValue: 5)

        var profileBytes = shaar_bytes()
        profileBytes.data = profileBuffer.baseAddress.map {
          UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
        }
        profileBytes.size = profile.count
        event.profile_id = profileBytes

        var payloadBytes = shaar_bytes()
        payloadBytes.data = payloadBuffer.baseAddress.map {
          UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
        }
        payloadBytes.size = payload.count
        event.payload_json = payloadBytes

        dispatcher.receive(event)
      }
    }
    for _ in 0..<20 where delivered == nil { await Task.yield() }
    #expect(delivered?.sequence == 42)
    #expect(delivered?.profileID == Data(profile))
    #expect(delivered?.payloadJSON == Data(payload))
  }

  @Test @MainActor func eventsReachMainActorInSequenceOrder() async {
    let count = 256
    let sequences = await withCheckedContinuation { continuation in
      var received: [UInt64] = []
      let dispatcher = ShaarEventDispatcher { event in
        received.append(event.sequence)
        if received.count == count { continuation.resume(returning: received) }
      }
      for sequence in 1...count {
        dispatcher.receive(engineEvent(sequence: UInt64(sequence)))
      }
    }
    #expect(sequences == (1...count).map(UInt64.init))
  }

  @Test @MainActor func invalidEventsAreReported() async {
    let reported = await withCheckedContinuation { continuation in
      let dispatcher = ShaarEventDispatcher(
        handler: { _ in Issue.record("invalid event was dispatched") },
        onError: { error in continuation.resume(returning: error) })
      dispatcher.receive(engineEvent(sequence: 1, kind: 5))
    }
    #expect(reported == .invalidEvent("profile-scoped event has no profile ID"))
  }

  @Test func frameworkLoadFailureHasItsOwnTypedError() {
    let frameworkURL = URL(fileURLWithPath: "/no/such/Shaar.framework")
    do {
      _ = try ShaarEngineLoader.load(frameworkURL: frameworkURL)
      Issue.record("loading a missing framework unexpectedly succeeded")
    } catch let error as ShaarEngineError {
      guard case .frameworkLoadFailed(let path, let reason) = error else {
        Issue.record("expected frameworkLoadFailed, got \(error)")
        return
      }
      #expect(path == frameworkURL.appending(path: "Versions/Current/Chromium Framework").path)
      #expect(!reason.isEmpty)
    } catch {
      Issue.record("expected ShaarEngineError, got \(error)")
    }
  }

  private func engineEvent(sequence: UInt64, kind: UInt32 = 1) -> shaar_event {
    var event = shaar_event()
    event.size = UInt32(MemoryLayout<shaar_event>.size)
    event.sequence = sequence
    event.kind = shaar_event_kind(rawValue: kind)
    return event
  }

}
