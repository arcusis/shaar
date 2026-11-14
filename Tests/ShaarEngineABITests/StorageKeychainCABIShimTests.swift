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

@Test func storageKeychainCShimRejectsShortImmediateErrorOutput() {
  let invalidArgument = UInt32(SHAAR_INVALID_ARGUMENT.rawValue)
  let symbol = UnsafeRawPointer(bitPattern: 1)
  let engine = OpaquePointer(bitPattern: 2)
  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size),
    profile: OpaquePointer(bitPattern: 3), private_session: nil)
  var error = shaar_error(
    size: UInt32(MemoryLayout<shaar_error>.size - 1), code: SHAAR_OK, platform_code: 0,
    message: shaar_bytes(data: nil, size: 0))

  let result = withUnsafePointer(to: &scope) { scopePointer in
    shaar_storage_keychain_submit_invoke(
      symbol, engine, scopePointer, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpStorageKeychainReply, nil, &error)
  }

  #expect(result == invalidArgument)
}
