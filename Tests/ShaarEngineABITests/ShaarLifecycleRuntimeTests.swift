// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineC
import Testing

@testable import ShaarEngineABI

private nonisolated(unsafe) var fakeEventCallback: ShaarEventCallback?
private nonisolated(unsafe) var fakeEventContext: UnsafeMutableRawPointer?
private nonisolated(unsafe) var fakeEngineReleased = false
private nonisolated(unsafe) var fakeLifecycleOrder: [String] = []

@_cdecl("fake_lifecycle_abi_major")
private func fakeLifecycleABIMajor() -> UInt32 { 1 }

@_cdecl("fake_lifecycle_abi_minor")
private func fakeLifecycleABIMinor() -> UInt32 { 0 }

@_cdecl("fake_lifecycle_create")
private func fakeLifecycleCreate(
  _ config: UnsafeRawPointer?,
  _ output: UnsafeMutablePointer<OpaquePointer?>?,
  _ error: UnsafeMutableRawPointer?
) -> UInt32 {
  guard let config, let output else { return ShaarStatusCode.invalidArgument.rawValue }
  let configuration = config.load(as: ShaarLifecycleConfig.self)
  fakeEventCallback = configuration.onEvent
  fakeEventContext = configuration.eventContext
  output.pointee = OpaquePointer(bitPattern: 0x44)
  if let error { error.assumingMemoryBound(to: ShaarLifecycleError.self).pointee.code = 0 }
  return ShaarStatusCode.ok.rawValue
}

@_cdecl("fake_lifecycle_create_with_invalid_error_message")
private func fakeLifecycleCreateWithInvalidErrorMessage(
  _ config: UnsafeRawPointer?,
  _ output: UnsafeMutablePointer<OpaquePointer?>?,
  _ error: UnsafeMutableRawPointer?
) -> UInt32 {
  guard config != nil, let output else { return ShaarStatusCode.invalidArgument.rawValue }
  output.pointee = nil
  if let error {
    let value = error.assumingMemoryBound(to: ShaarLifecycleError.self)
    value.pointee.code = ShaarStatusCode.invalidArgument.rawValue
    value.pointee.message = ShaarBytes(data: nil, size: 1)
  }
  return ShaarStatusCode.invalidArgument.rawValue
}

@_cdecl("fake_lifecycle_create_with_short_error_struct")
private func fakeLifecycleCreateWithShortErrorStruct(
  _ config: UnsafeRawPointer?,
  _ output: UnsafeMutablePointer<OpaquePointer?>?,
  _ error: UnsafeMutableRawPointer?
) -> UInt32 {
  guard config != nil, let output else { return ShaarStatusCode.invalidArgument.rawValue }
  output.pointee = nil
  if let error {
    let value = error.assumingMemoryBound(to: ShaarLifecycleError.self)
    value.pointee.size = 0
    value.pointee.code = ShaarStatusCode.invalidArgument.rawValue
  }
  return ShaarStatusCode.invalidArgument.rawValue
}

@_cdecl("fake_lifecycle_run")
private func fakeLifecycleRun(
  _ engine: OpaquePointer?, _ error: UnsafeMutableRawPointer?
) -> UInt32 {
  fakeLifecycleOrder.append("run")
  guard engine != nil else { return ShaarStatusCode.invalidArgument.rawValue }
  let payload = Array("{\"kind\":\"engine.ready\",\"schemaVersion\":1}".utf8)
  payload.withUnsafeBufferPointer { buffer in
    var event = ShaarABIEvent()
    event.size = UInt32(MemoryLayout<ShaarABIEvent>.size)
    event.sequence = 1
    event.kind = shaar_event_kind(rawValue: 1)
    var payloadBytes = ShaarBytes()
    payloadBytes.data = buffer.baseAddress.map {
      UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
    }
    payloadBytes.size = buffer.count
    event.payload_json = payloadBytes
    withUnsafePointer(to: event) { eventPointer in
      fakeEventCallback?(fakeEventContext, UnsafeRawPointer(eventPointer))
    }
  }
  if let error { error.assumingMemoryBound(to: ShaarLifecycleError.self).pointee.code = 0 }
  return ShaarStatusCode.ok.rawValue
}

@_cdecl("fake_lifecycle_request_quit")
private func fakeLifecycleRequestQuit(
  _ engine: OpaquePointer?, _ error: UnsafeMutableRawPointer?
) -> UInt32 {
  guard engine != nil else { return ShaarStatusCode.invalidArgument.rawValue }
  if let error { error.assumingMemoryBound(to: ShaarLifecycleError.self).pointee.code = 0 }
  return ShaarStatusCode.ok.rawValue
}

@_cdecl("fake_lifecycle_release")
private func fakeLifecycleRelease(_ engine: OpaquePointer?) {
  fakeLifecycleOrder.append("release")
  fakeEngineReleased = engine != nil
}

private struct FakeLifecycleResolver: ShaarSymbolResolving {
  let invalidErrorMessage: Bool
  let shortErrorStruct: Bool

  init(invalidErrorMessage: Bool = false, shortErrorStruct: Bool = false) {
    self.invalidErrorMessage = invalidErrorMessage
    self.shortErrorStruct = shortErrorStruct
  }

  func symbol(named: String) -> UnsafeRawPointer? {
    switch named {
    case "shaar_abi_major":
      return unsafeBitCast(
        fakeLifecycleABIMajor as @convention(c) () -> UInt32,
        to: UnsafeRawPointer.self)
    case "shaar_abi_minor":
      return unsafeBitCast(
        fakeLifecycleABIMinor as @convention(c) () -> UInt32,
        to: UnsafeRawPointer.self)
    case "shaar_engine_create":
      if shortErrorStruct {
        return unsafeBitCast(
          fakeLifecycleCreateWithShortErrorStruct as ShaarCreateFunction,
          to: UnsafeRawPointer.self)
      }
      if invalidErrorMessage {
        return unsafeBitCast(
          fakeLifecycleCreateWithInvalidErrorMessage as ShaarCreateFunction,
          to: UnsafeRawPointer.self)
      }
      return unsafeBitCast(fakeLifecycleCreate as ShaarCreateFunction, to: UnsafeRawPointer.self)
    case "shaar_engine_run":
      return unsafeBitCast(fakeLifecycleRun as ShaarRunFunction, to: UnsafeRawPointer.self)
    case "shaar_engine_request_quit":
      return unsafeBitCast(
        fakeLifecycleRequestQuit as ShaarRequestQuitFunction,
        to: UnsafeRawPointer.self)
    case "shaar_engine_release":
      return unsafeBitCast(
        fakeLifecycleRelease as ShaarReleaseFunction,
        to: UnsafeRawPointer.self)
    case "shaar_submit":
      return unsafeBitCast(
        fakeLifecycleABIMajor as @convention(c) () -> UInt32,
        to: UnsafeRawPointer.self)
    case "shaar_cancel_request":
      return unsafeBitCast(
        fakeLifecycleABIMajor as @convention(c) () -> UInt32,
        to: UnsafeRawPointer.self)
    default: return nil
    }
  }
}

@Suite("Shaar lifecycle adapter")
struct ShaarLifecycleRuntimeTests {
  @Test @MainActor func fakeEngineCreatesRunsCopiesReadyEventAndReleases() async throws {
    fakeEngineReleased = false
    fakeLifecycleOrder = []
    var delivered: ShaarCopiedEvent?
    let runtime = try ShaarLifecycleRuntime(
      resolver: FakeLifecycleResolver(), dataRoot: URL(fileURLWithPath: "/tmp/shaar-test"),
      locale: "en-US", onEvent: { delivered = $0 })
    try runtime.run()
    for _ in 0..<20 where delivered == nil { await Task.yield() }
    #expect(delivered?.sequence == 1)
    #expect(
      String(decoding: delivered?.payloadJSON ?? Data(), as: UTF8.self)
        == "{\"kind\":\"engine.ready\",\"schemaVersion\":1}")
    #expect(
      throws: ShaarEngineError.status(
        .notReady, platformCode: 0,
        message: "engine is not running")
    ) {
      try runtime.requestQuit()
    }
    runtime.release()
    #expect(fakeEngineReleased)
    #expect(fakeLifecycleOrder == ["run", "release"])
  }

  @Test @MainActor func runtimeRejectsMissingLifecycleExportsBeforeCreate() {
    struct MissingQuitResolver: ShaarSymbolResolving {
      func symbol(named: String) -> UnsafeRawPointer? {
        guard named != "shaar_engine_request_quit" else { return nil }
        return FakeLifecycleResolver().symbol(named: named)
      }
    }
    #expect(throws: ShaarEngineError.missingSymbol("shaar_engine_request_quit")) {
      try ShaarLifecycleRuntime(
        resolver: MissingQuitResolver(), dataRoot: URL(fileURLWithPath: "/tmp/shaar-test"),
        locale: "en-US", onEvent: { _ in })
    }
  }

  @Test @MainActor func runtimeRejectsNonemptyErrorMessageWithNullData() {
    #expect(throws: ShaarEngineError.invalidEvent("invalid lifecycle error message slice")) {
      try ShaarLifecycleRuntime(
        resolver: FakeLifecycleResolver(invalidErrorMessage: true),
        dataRoot: URL(fileURLWithPath: "/tmp/shaar-test"), locale: "en-US", onEvent: { _ in })
    }
  }

  @Test @MainActor func runtimeRejectsShortErrorStructBeforeDecodingItsFields() {
    #expect(throws: ShaarEngineError.invalidEvent("short lifecycle error")) {
      try ShaarLifecycleRuntime(
        resolver: FakeLifecycleResolver(shortErrorStruct: true),
        dataRoot: URL(fileURLWithPath: "/tmp/shaar-test"), locale: "en-US", onEvent: { _ in })
    }
  }
}
