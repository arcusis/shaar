// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import ShaarEngineC
import Testing

@testable import ShaarEngineABI

private typealias DevToolsShimSubmit = @convention(c) (
  OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
  shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
  UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code

@_cdecl("fake_devtools_submit_short_error_struct")
private func fakeDevToolsSubmitShortErrorStruct(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let reply, let replyContext else {
    return shaar_error_code(rawValue: 1)
  }
  let contextAddress = UInt(bitPattern: replyContext)
  let callback = reply
  DispatchQueue.global().async {
    let context = UnsafeMutableRawPointer(bitPattern: contextAddress)!
    let payload = Data(#"{"schemaVersion":1}"#.utf8)
    payload.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      var result = shaar_result(
        size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
        error: shaar_error(
          size: 0, code: SHAAR_OK, platform_code: 0,
          message: shaar_bytes(data: nil, size: 0)),
        payload_json: shaar_bytes(data: bytes.baseAddress, size: bytes.count))
      callback(context, &result)
    }
  }
  return SHAAR_OK
}

@_cdecl("fake_devtools_submit_short_immediate_error")
private func fakeDevToolsSubmitShortImmediateError(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, let immediateError else { return shaar_error_code(rawValue: 1) }
  immediateError.pointee.size = 0
  immediateError.pointee.code = shaar_error_code(rawValue: 4)
  return shaar_error_code(rawValue: 4)
}

private struct FakeDevToolsABISymbols: ShaarSymbolResolving {
  var shortImmediateError = false

  func symbol(named: String) -> UnsafeRawPointer? {
    guard named == "shaar_submit" else { return nil }
    if shortImmediateError {
      return unsafeBitCast(
        fakeDevToolsSubmitShortImmediateError as DevToolsShimSubmit,
        to: UnsafeRawPointer.self)
    }
    return unsafeBitCast(
      fakeDevToolsSubmitShortErrorStruct as DevToolsShimSubmit, to: UnsafeRawPointer.self)
  }
}

private struct FakeDevToolsABIHandleResolver: ShaarNavigationHandleResolving {
  func resolve(
    scope: ShaarNavigationScope, windowID: String, tabID: String
  ) throws -> ShaarABINativeHandles {
    ShaarABINativeHandles(
      engine: OpaquePointer(bitPattern: 0x44)!,
      scope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size),
        profile: OpaquePointer(bitPattern: 0x11)!, private_session: nil),
      window: OpaquePointer(bitPattern: 0x22)!, tab: OpaquePointer(bitPattern: 0x33)!)
  }
}

@Test func devToolsTransportRejectsShortNestedErrorStruct() async throws {
  let transport = try ShaarDevToolsABITransport(
    resolver: FakeDevToolsABISymbols(), handleResolver: FakeDevToolsABIHandleResolver())
  let request = ShaarDevToolsRequest(
    operation: .call, scope: ShaarNavigationScope(profileID: "profile"),
    windowID: "window", tabID: "tab", payload: Data(#"{"schemaVersion":1}"#.utf8))
  let result = await withCheckedContinuation {
    (continuation: CheckedContinuation<Result<Data, ShaarEngineError>, Never>) in
    do {
      _ = try transport.submit(request) { continuation.resume(returning: $0) }
    } catch let error as ShaarEngineError {
      continuation.resume(returning: .failure(error))
    } catch {
      continuation.resume(returning: .failure(.invalidEvent("unexpected DevTools error")))
    }
  }
  #expect(result == .failure(.invalidEvent("short DevTools error")))
}

@Test func devToolsTransportRejectsShortImmediateErrorStruct() throws {
  let transport = try ShaarDevToolsABITransport(
    resolver: FakeDevToolsABISymbols(shortImmediateError: true),
    handleResolver: FakeDevToolsABIHandleResolver())
  let request = ShaarDevToolsRequest(
    operation: .call, scope: ShaarNavigationScope(profileID: "profile"),
    windowID: "window", tabID: "tab", payload: Data(#"{"schemaVersion":1}"#.utf8))
  #expect(throws: ShaarEngineError.invalidEvent("short DevTools error")) {
    try transport.submit(request) { _ in Issue.record("unexpected asynchronous reply") }
  }
}
