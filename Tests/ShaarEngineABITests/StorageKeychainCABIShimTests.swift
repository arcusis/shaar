// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import ShaarStorageKeychainABIC
import Testing

private let noOpStorageKeychainReply:
  @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<shaar_result>?
  ) -> Void = { _, _ in }

private let fakeStorageKeychainSubmitSuccess: @convention(c) (
  OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
  shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
  UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code = { _, _, _, _, _, _, _, _, _, _ in
  shaar_error_code(rawValue: 0)
}

@Test func storageKeychainCShimRejectsMissingRequiredPointers() {
  let invalidArgument = UInt32(shaar_error_code(rawValue: 1).rawValue)
  let noSymbol = shaar_storage_keychain_submit_invoke(
    nil, nil, nil, 0, shaar_bytes(data: nil, size: 0), 1, nil, nil, nil)
  #expect(noSymbol == invalidArgument)

  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
    private_session: nil)
  withUnsafePointer(to: &scope) { scopePointer in
    let symbol = UnsafeRawPointer(bitPattern: 1)
    let noEngine = shaar_storage_keychain_submit_invoke(
      symbol, nil, scopePointer, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpStorageKeychainReply, nil, nil)
    #expect(noEngine == invalidArgument)

    let engine = OpaquePointer(bitPattern: 1)
    let noScope = shaar_storage_keychain_submit_invoke(
      symbol, engine, nil, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpStorageKeychainReply, nil, nil)
    #expect(noScope == invalidArgument)

    var error = shaar_error()
    let noReply = shaar_storage_keychain_submit_invoke(
      symbol, engine, scopePointer, 0, shaar_bytes(data: nil, size: 0), 1, nil, nil, &error)
    #expect(noReply == invalidArgument)

    let noErrorOutput = shaar_storage_keychain_submit_invoke(
      symbol, engine, scopePointer, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpStorageKeychainReply, nil, nil)
    #expect(noErrorOutput == invalidArgument)
  }
}

@Test func storageKeychainCShimRejectsPrivateSessionScopes() {
  let submitSymbol = unsafeBitCast(fakeStorageKeychainSubmitSuccess, to: UnsafeRawPointer.self)
  let engine = OpaquePointer(bitPattern: 0x11)!
  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
    private_session: OpaquePointer(bitPattern: 0x22))
  var error = shaar_error()
  let status = withUnsafePointer(to: &scope) { scopePointer in
    shaar_storage_keychain_submit_invoke(
      submitSymbol, engine, scopePointer, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpStorageKeychainReply, nil, &error)
  }
  #expect(status == UInt32(shaar_error_code(rawValue: 1).rawValue))
}
