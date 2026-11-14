// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineABIC
import ShaarEngineC
import Testing

private typealias NavigationShimSubmit = @convention(c) (
  OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
  shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
  UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code

private let noOpNavigationReply: shaar_reply_fn = { _, _ in }

@_cdecl("fake_navigation_c_shim_submit")
private func fakeNavigationCShimSubmit(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ args: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  engine != nil && reply != nil ? SHAAR_OK : SHAAR_CONFLICT
}

@Test func navigationCShimRejectsMissingRequiredPointers() {
  let invalidArgument = UInt32(shaar_error_code(rawValue: 1).rawValue)
  let noSymbol = shaar_navigation_submit_invoke(
    nil, nil, nil, nil, nil, 0, shaar_bytes(data: nil, size: 0), 1, nil, nil, nil)
  #expect(noSymbol == invalidArgument)

  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
    private_session: nil)
  let noErrorOutput = withUnsafePointer(to: &scope) { scopePointer in
    shaar_navigation_submit_invoke(
      UnsafeRawPointer(bitPattern: 1), nil, scopePointer, nil, nil, 0,
      shaar_bytes(data: nil, size: 0), 1, nil, nil, nil)
  }
  #expect(noErrorOutput == invalidArgument)

  var immediateError = shaar_error(
    size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK,
    platform_code: 0, message: shaar_bytes(data: nil, size: 0))
  let noEngine = withUnsafePointer(to: &scope) { scopePointer in
    withUnsafeMutablePointer(to: &immediateError) { errorPointer in
      shaar_navigation_submit_invoke(
        UnsafeRawPointer(bitPattern: 1), nil, scopePointer, nil, nil, 0,
        shaar_bytes(data: nil, size: 0), 1, noOpNavigationReply, nil, errorPointer)
    }
  }
  #expect(noEngine == invalidArgument)

  let invalidEngine = OpaquePointer(bitPattern: 1)
  let noReply = withUnsafePointer(to: &scope) { scopePointer in
    withUnsafeMutablePointer(to: &immediateError) { errorPointer in
      shaar_navigation_submit_invoke(
        UnsafeRawPointer(bitPattern: 1), invalidEngine, scopePointer, nil, nil, 0,
        shaar_bytes(data: nil, size: 0), 1, nil, nil, errorPointer)
    }
  }
  #expect(noReply == invalidArgument)
}

@Test func navigationCShimRejectsMissingEngineAndReply() {
  let invalidArgument = UInt32(SHAAR_INVALID_ARGUMENT.rawValue)
  let symbol = unsafeBitCast(fakeNavigationCShimSubmit as NavigationShimSubmit,
                             to: UnsafeRawPointer.self)
  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size),
    profile: OpaquePointer(bitPattern: 0x11), private_session: nil)
  var error = shaar_error(
    size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK, platform_code: 0,
    message: shaar_bytes(data: nil, size: 0))

  let noEngine = withUnsafePointer(to: &scope) { scopePointer in
    shaar_navigation_submit_invoke(
      symbol, nil, scopePointer, nil, nil, 0, shaar_bytes(data: nil, size: 0), 1,
      noOpNavigationShimReply, nil, &error)
  }
  #expect(noEngine == invalidArgument)

  let noReply = withUnsafePointer(to: &scope) { scopePointer in
    shaar_navigation_submit_invoke(
      symbol, OpaquePointer(bitPattern: 0x22), scopePointer, nil, nil, 0,
      shaar_bytes(data: nil, size: 0), 1, nil, nil, &error)
  }
  #expect(noReply == invalidArgument)
}

@Test func navigationCShimRejectsTruncatedScopeBeforeCopyingIt() {
  let invalidArgument = UInt32(SHAAR_INVALID_ARGUMENT.rawValue)
  let symbol = unsafeBitCast(fakeNavigationCShimSubmit as NavigationShimSubmit,
                             to: UnsafeRawPointer.self)
  var scope = shaar_scope(size: 0, profile: nil, private_session: nil)
  var error = shaar_error(
    size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK, platform_code: 0,
    message: shaar_bytes(data: nil, size: 0))
  let status = withUnsafePointer(to: &scope) { scopePointer in
    shaar_navigation_submit_invoke(
      symbol, OpaquePointer(bitPattern: 0x22), scopePointer, nil, nil, 0,
      shaar_bytes(data: nil, size: 0), 1, noOpNavigationShimReply, nil, &error)
  }
  #expect(status == invalidArgument)
}
