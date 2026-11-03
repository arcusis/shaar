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
