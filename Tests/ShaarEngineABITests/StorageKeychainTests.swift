// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import ShaarStorageKeychainABIC
import Testing

@testable import ShaarEngineABI

private actor FakeStorageKeychainTransport: ShaarStorageKeychainTransport {
  struct Call: Equatable, Sendable {
    let profileID: UUID
    let operation: UInt32
    let arguments: Data
  }

  private let reply: Data
  private(set) var calls: [Call] = []

  init(reply: String) { self.reply = Data(reply.utf8) }

  func submitStorageKeychain(
    profileID: UUID,
    operation: UInt32,
    arguments: Data
  ) async throws -> Data {
    calls.append(Call(profileID: profileID, operation: operation, arguments: arguments))
    return reply
  }
}

private struct FakeStorageKeychainProfileResolver: ShaarStorageKeychainProfileResolving,
  @unchecked Sendable
{
  let nativeScope: shaar_scope

  func resolve(profileID: UUID) async throws -> ShaarStorageKeychainNativeProfile {
    ShaarStorageKeychainNativeProfile(
      engine: OpaquePointer(bitPattern: 0x44)!, scope: nativeScope)
  }
}

private final class FakeStorageKeychainSubmitCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOperation: UInt32?
  private var storedArguments: Data?
  private var storedProfile: UInt?

  func record(scope: shaar_scope, operation: shaar_operation, arguments: shaar_bytes) {
    let copied = arguments.data.map { Data(bytes: $0, count: arguments.size) } ?? Data()
    lock.lock()
    storedOperation = operation.rawValue
    storedArguments = copied
    storedProfile = scope.profile.map(UInt.init(bitPattern:))
    lock.unlock()
  }

  var snapshot: (UInt32?, Data?, UInt?) {
    lock.lock()
    defer { lock.unlock() }
    return (storedOperation, storedArguments, storedProfile)
  }
}

private let fakeStorageKeychainSubmitCapture = FakeStorageKeychainSubmitCapture()

@_cdecl("fake_shaar_storage_keychain_abi_major")
private func fakeStorageKeychainABIMajor() -> UInt32 { 1 }

@_cdecl("fake_shaar_storage_keychain_engine_create")
private func fakeStorageKeychainEngineCreate() -> UInt32 { 0 }

@_cdecl("fake_shaar_storage_keychain_submit")
private func fakeStorageKeychainSubmit(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let reply, let replyContext,
    window == nil, tab == nil, scope.private_session == nil
  else { return shaar_error_code(rawValue: 1) }
  fakeStorageKeychainSubmitCapture.record(
    scope: scope, operation: operation, arguments: arguments)
  let replyAddress = UInt(bitPattern: replyContext)
  let replyFunction = reply
  DispatchQueue.global().async {
    let context = UnsafeMutableRawPointer(bitPattern: replyAddress)!
    let payload = Data(#"{"schemaVersion":1,"identity":"shaar"}"#.utf8)
    payload.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      var result = shaar_result(
        size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
        error: shaar_error(
          size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
          platform_code: 0, message: shaar_bytes(data: nil, size: 0)),
        payload_json: shaar_bytes(data: bytes.baseAddress, size: bytes.count))
      replyFunction(context, &result)
    }
  }
  return shaar_error_code(rawValue: 0)
}

@_cdecl("fake_shaar_storage_keychain_submit_mismatched_request_id")
private func fakeStorageKeychainSubmitMismatchedRequestID(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let reply, let replyContext,
    window == nil, tab == nil, scope.private_session == nil
  else { return shaar_error_code(rawValue: 1) }
  let replyAddress = UInt(bitPattern: replyContext)
  let replyFunction = reply
  DispatchQueue.global().async {
    let context = UnsafeMutableRawPointer(bitPattern: replyAddress)!
    let payload = Data(#"{"schemaVersion":1,"identity":"shaar"}"#.utf8)
    payload.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      var result = shaar_result(
        size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID &+ 1,
        error: shaar_error(
          size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
          platform_code: 0, message: shaar_bytes(data: nil, size: 0)),
        payload_json: shaar_bytes(data: bytes.baseAddress, size: bytes.count))
      replyFunction(context, &result)
    }
  }
  return shaar_error_code(rawValue: 0)
}

private struct FakeMismatchedRequestIDStorageKeychainSymbols: ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer? {
    guard named == "shaar_submit" else { return nil }
    let function =
      fakeStorageKeychainSubmitMismatchedRequestID
      as @convention(c) (
        OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
        shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<shaar_error>?
      ) -> shaar_error_code
    return unsafeBitCast(function, to: UnsafeRawPointer.self)
  }
}

@_cdecl("fake_shaar_storage_keychain_submit_invalid_slice")
private func fakeStorageKeychainSubmitInvalidSlice(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let reply, let replyContext,
    window == nil, tab == nil, scope.private_session == nil
  else { return shaar_error_code(rawValue: 1) }
  let replyAddress = UInt(bitPattern: replyContext)
  let replyFunction = reply
  DispatchQueue.global().async {
    let context = UnsafeMutableRawPointer(bitPattern: replyAddress)!
    var result = shaar_result(
      size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
      error: shaar_error(
        size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
        platform_code: 0, message: shaar_bytes(data: nil, size: 0)),
      payload_json: shaar_bytes(data: nil, size: 1))
    replyFunction(context, &result)
  }
  return shaar_error_code(rawValue: 0)
}

@_cdecl("fake_shaar_storage_keychain_submit_short_error")
private func fakeStorageKeychainSubmitShortError(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let reply, let replyContext,
    window == nil, tab == nil, scope.private_session == nil
  else { return shaar_error_code(rawValue: 1) }
  let replyAddress = UInt(bitPattern: replyContext)
  let replyFunction = reply
  DispatchQueue.global().async {
    let context = UnsafeMutableRawPointer(bitPattern: replyAddress)!
    let payload = Data(#"{"schemaVersion":1,"identity":"shaar"}"#.utf8)
    payload.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      var result = shaar_result(
        size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
        error: shaar_error(
          size: 0, code: shaar_error_code(rawValue: 0), platform_code: 0,
          message: shaar_bytes(data: nil, size: 0)),
        payload_json: shaar_bytes(data: bytes.baseAddress, size: bytes.count))
      replyFunction(context, &result)
    }
  }
  return shaar_error_code(rawValue: 0)
}

@_cdecl("fake_shaar_storage_keychain_submit_short_immediate_error")
private func fakeStorageKeychainSubmitShortImmediateError(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let immediateError, window == nil, tab == nil,
    scope.private_session == nil
  else { return shaar_error_code(rawValue: 1) }
  immediateError.pointee.size = 0
  immediateError.pointee.code = shaar_error_code(rawValue: 4)
  return shaar_error_code(rawValue: 4)
}

private struct FakeStorageKeychainABISymbols: ShaarSymbolResolving {
  var invalidResultSlice = false
  var shortErrorStruct = false
  var shortImmediateError = false

  func symbol(named: String) -> UnsafeRawPointer? {
    switch named {
    case "shaar_abi_major":
      let function = fakeStorageKeychainABIMajor as @convention(c) () -> UInt32
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_engine_create":
      let function = fakeStorageKeychainEngineCreate as @convention(c) () -> UInt32
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_submit":
      let function: @convention(c) (
          OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
          shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
          UnsafeMutablePointer<shaar_error>?
      ) -> shaar_error_code = invalidResultSlice
          ? fakeStorageKeychainSubmitInvalidSlice
          : shortErrorStruct
            ? fakeStorageKeychainSubmitShortError
            : shortImmediateError
              ? fakeStorageKeychainSubmitShortImmediateError : fakeStorageKeychainSubmit
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    default:
      return nil
    }
  }
}

@Suite("Storage keychain")
struct StorageKeychainTests {
  @Test func shippingDefaultUsesShaarStatusRoute() async throws {
    let profile = UUID()
    let fake = FakeStorageKeychainTransport(
      reply: #"{"schemaVersion":1,"identity":"shaar"}"#)

    #expect(ShaarEngineImplementation.shippingDefault == .shaar)
    #expect(ShaarStorageKeychainAdapter.selected(transport: fake).map { _ in true } == true)
    let adapter = try #require(
      ShaarStorageKeychainAdapter.selected(implementation: .shaar, transport: fake))
    #expect(try await adapter.configuredIdentity(for: profile) == .shaar)

    let calls = await fake.calls
    #expect(calls.count == 1)
    #expect(calls[0].profileID == profile)
    #expect(calls[0].operation == ShaarStorageKeychainAdapter.identityOperation)
    #expect(calls[0].arguments == Data(#"{"schemaVersion":1}"#.utf8))
  }

  @Test func rejectsUnknownIdentityAndSecretBearingFields() async {
    let profile = UUID()
    let unknown = ShaarStorageKeychainAdapter(
      transport: FakeStorageKeychainTransport(
        reply: #"{"schemaVersion":1,"identity":"unknown"}"#))
    await #expect(throws: ShaarStorageKeychainError.malformedResponse) {
      try await unknown.configuredIdentity(for: profile)
    }

    let secretField = ShaarStorageKeychainAdapter(
      transport: FakeStorageKeychainTransport(
        reply: #"{"schemaVersion":1,"identity":"shaar","password":"never"}"#))
    await #expect(throws: ShaarStorageKeychainError.malformedResponse) {
      try await secretField.configuredIdentity(for: profile)
    }
  }

  @Test func rejectsMalformedOrUnsupportedIdentityReplies() async {
    let profile = UUID()
    for reply in [
      "not-json",
      #"{"schemaVersion":2,"identity":"shaar"}"#,
      #"{"schemaVersion":true,"identity":"shaar"}"#,
      #"{"schemaVersion":1,"identity":7}"#,
    ] {
      let adapter = ShaarStorageKeychainAdapter(
        transport: FakeStorageKeychainTransport(reply: reply))
      await #expect(throws: ShaarStorageKeychainError.malformedResponse) {
        try await adapter.configuredIdentity(for: profile)
      }
    }
  }

  @Test func loaderWiresSelectedAdapterThroughProfileOnlySubmitABI() async throws {
    let profileHandle = OpaquePointer(bitPattern: 0x11)!
    let resolver = FakeStorageKeychainProfileResolver(
      nativeScope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size), profile: profileHandle,
        private_session: nil))
    let loader = try ShaarEngineLoader(
      resolver: FakeStorageKeychainABISymbols(), implementation: .shaar)
    let selected = try loader.makeStorageKeychainAdapter(profileResolver: resolver)
    let adapter = try #require(selected)

    #expect(try await adapter.configuredIdentity(for: UUID()) == .shaar)
    let call = fakeStorageKeychainSubmitCapture.snapshot
    #expect(call.0 == ShaarStorageKeychainAdapter.identityOperation)
    #expect(call.1 == Data(#"{"schemaVersion":1}"#.utf8))
    #expect(call.2 == UInt(bitPattern: profileHandle))
  }

  @Test func loaderProvidesStorageKeychainOnShaarDefault() throws {
    let loader = try ShaarEngineLoader(
      resolver: FakeStorageKeychainABISymbols(), implementation: .shippingDefault)
    let profile = OpaquePointer(bitPattern: 0x11)!
    let resolver = FakeStorageKeychainProfileResolver(
      nativeScope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile,
        private_session: nil))

    #expect(try loader.makeStorageKeychainAdapter(profileResolver: resolver) != nil)
  }

  @Test func concreteTransportRejectsPrivateProfileScope() async throws {
    let transport = try ShaarStorageKeychainABITransport(
      resolver: FakeStorageKeychainABISymbols(),
      profileResolver: FakeStorageKeychainProfileResolver(
        nativeScope: shaar_scope(
          size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
          private_session: OpaquePointer(bitPattern: 0x22))))

    await #expect(throws: ShaarEngineError.self) {
      try await transport.submitStorageKeychain(
        profileID: UUID(), operation: ShaarStorageKeychainAdapter.identityOperation,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }

  @Test func concreteTransportRejectsNonemptyNilResultBytes() async throws {
    let profile = OpaquePointer(bitPattern: 0x11)!
    let transport = try ShaarStorageKeychainABITransport(
      resolver: FakeStorageKeychainABISymbols(invalidResultSlice: true),
      profileResolver: FakeStorageKeychainProfileResolver(
        nativeScope: shaar_scope(
          size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile,
          private_session: nil)))
    await #expect(throws: ShaarEngineError.self) {
      try await transport.submitStorageKeychain(
        profileID: UUID(), operation: ShaarStorageKeychainAdapter.identityOperation,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }

  @Test func concreteTransportRejectsMismatchedResultRequestID() async throws {
    let profile = OpaquePointer(bitPattern: 0x11)!
    let transport = try ShaarStorageKeychainABITransport(
      resolver: FakeMismatchedRequestIDStorageKeychainSymbols(),
      profileResolver: FakeStorageKeychainProfileResolver(
        nativeScope: shaar_scope(
          size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile,
          private_session: nil)))
    await #expect(throws: ShaarEngineError.invalidEvent("storage-keychain result does not match request")) {
      try await transport.submitStorageKeychain(
        profileID: UUID(), operation: ShaarStorageKeychainAdapter.identityOperation,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }

  @Test func concreteTransportRejectsShortNestedErrorStruct() async throws {
    let profile = OpaquePointer(bitPattern: 0x11)!
    let transport = try ShaarStorageKeychainABITransport(
      resolver: FakeStorageKeychainABISymbols(shortErrorStruct: true),
      profileResolver: FakeStorageKeychainProfileResolver(
        nativeScope: shaar_scope(
          size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile,
          private_session: nil)))
    await #expect(throws: ShaarEngineError.invalidEvent("short storage-keychain error")) {
      try await transport.submitStorageKeychain(
        profileID: UUID(), operation: ShaarStorageKeychainAdapter.identityOperation,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }

  @Test func concreteTransportRejectsShortImmediateErrorStruct() async throws {
    let profile = OpaquePointer(bitPattern: 0x11)!
    let transport = try ShaarStorageKeychainABITransport(
      resolver: FakeStorageKeychainABISymbols(shortImmediateError: true),
      profileResolver: FakeStorageKeychainProfileResolver(
        nativeScope: shaar_scope(
          size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile,
          private_session: nil)))
    await #expect(throws: ShaarEngineError.invalidEvent("short storage-keychain error")) {
      try await transport.submitStorageKeychain(
        profileID: UUID(), operation: ShaarStorageKeychainAdapter.identityOperation,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }
}
