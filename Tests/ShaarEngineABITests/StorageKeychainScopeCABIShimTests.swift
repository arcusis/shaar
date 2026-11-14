// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import ShaarStorageKeychainABIC
import Testing

private typealias StorageKeychainShimSubmit = @convention(c) (
  OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
  shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
  UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code

private let noOpStorageScopeReply: shaar_reply_fn = { _, _ in }

@_cdecl("fake_storage_scope_size_submit")
private func fakeStorageScopeSizeSubmit(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ args: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  shaar_error_code(
    rawValue: scope.size < UInt32(MemoryLayout<shaar_scope>.size) ? 10 : 0)
}

@Test func storageKeychainCShimRejectsTruncatedScopeBeforeCopyingIt() {
  let symbol = unsafeBitCast(fakeStorageScopeSizeSubmit as StorageKeychainShimSubmit,
                             to: UnsafeRawPointer.self)
  var scope = shaar_scope(size: 0, profile: nil, private_session: nil)
  var error = shaar_error(
    size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
    platform_code: 0, message: shaar_bytes(data: nil, size: 0))
  let status = withUnsafePointer(to: &scope) { scopePointer in
    shaar_storage_keychain_submit_invoke(
      symbol, OpaquePointer(bitPattern: 0x22), scopePointer, 0,
      shaar_bytes(data: nil, size: 0), 1, noOpStorageScopeReply, nil, &error)
  }
  #expect(status == UInt32(shaar_error_code(rawValue: 1).rawValue))
}
