// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC

public protocol ShaarSiteDataTransport: Sendable {
  func submit(
    operation: ShaarSiteDataOperation, scope: ShaarSiteDataScope,
    windowID: String?, tabID: String?, arguments: Data
  ) async throws -> Data
}

public struct ShaarSiteDataScope: Equatable, Sendable {
  public let profileID: String
  public let privateSessionID: String?

  public init(profileID: String, privateSessionID: String? = nil) {
    self.profileID = profileID
    self.privateSessionID = privateSessionID
  }
}

public struct ShaarSiteDataNativeHandles: @unchecked Sendable {
  public let engine: OpaquePointer
  public let scope: shaar_scope
  public let window: OpaquePointer?
  public let tab: OpaquePointer?

  public init(
    engine: OpaquePointer, scope: shaar_scope, window: OpaquePointer?, tab: OpaquePointer?
  ) {
    self.engine = engine
    self.scope = scope
    self.window = window
    self.tab = tab
  }
}

public protocol ShaarSiteDataHandleResolving: Sendable {
  func resolve(
    scope: ShaarSiteDataScope, windowID: String?, tabID: String?
  ) throws -> ShaarSiteDataNativeHandles
}

private final class ShaarSiteDataReplyBox: @unchecked Sendable {
  let requestID: UInt64
  let continuation: CheckedContinuation<Data, Error>
  init(requestID: UInt64, continuation: CheckedContinuation<Data, Error>) {
    self.requestID = requestID
    self.continuation = continuation
  }
}

private final class ShaarSiteDataRequestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var next: UInt64 = 1
  func take() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let value = next
    next &+= 1
    if next == 0 { next = 1 }
    return value
  }
}

private func copySiteDataBytes(_ bytes: shaar_bytes) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid site-data ABI bytes")
  }
  guard bytes.size > 0, let pointer = bytes.data else { return Data() }
  return Data(bytes: pointer, count: bytes.size)
}

private let shaarSiteDataReply: shaar_reply_fn = { context, result in
  guard let context else { return }
  let box = Unmanaged<ShaarSiteDataReplyBox>.fromOpaque(context).takeRetainedValue()
  guard let result else {
    box.continuation.resume(throwing: ShaarEngineError.invalidEvent("missing site-data result"))
    return
  }
  do {
    let value = result.pointee
    guard value.size >= UInt32(MemoryLayout<shaar_result>.size),
      value.request_id == box.requestID
    else { throw ShaarEngineError.invalidEvent("invalid site-data result header") }
    try ShaarStatusCode.decode(
      UInt32(value.error.code.rawValue), platformCode: value.error.platform_code,
      message: String(decoding: try copySiteDataBytes(value.error.message), as: UTF8.self))
    let payload = try copySiteDataBytes(value.payload_json)
    guard !payload.isEmpty,
      let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      object["schemaVersion"] as? Int == 1
    else { throw ShaarEngineError.invalidEvent("invalid site-data response payload") }
    box.continuation.resume(returning: payload)
  } catch {
    box.continuation.resume(throwing: error)
  }
}

/// Calls the shared submit entry point with explicitly resolved profile/session and optional tab
/// handles. The resolver owns all opaque-handle maps; IDs are never interpreted as native pointers.
public struct ShaarSiteDataABITransport: ShaarSiteDataTransport, @unchecked Sendable {
  private let submitSymbol: UnsafeRawPointer
  private let resolver: any ShaarSiteDataHandleResolving
  private let requestIDs = ShaarSiteDataRequestIDs()

  public init(resolver: ShaarSymbolResolving, handleResolver: any ShaarSiteDataHandleResolving)
    throws
  {
    guard let symbol = resolver.symbol(named: "shaar_submit") else {
      throw ShaarEngineError.missingSymbol("shaar_submit")
    }
    submitSymbol = symbol
    self.resolver = handleResolver
  }

  public func submit(
    operation: ShaarSiteDataOperation, scope: ShaarSiteDataScope,
    windowID: String?, tabID: String?, arguments: Data
  ) async throws -> Data {
    let handles = try resolver.resolve(scope: scope, windowID: windowID, tabID: tabID)
    guard handles.scope.size >= UInt32(MemoryLayout<shaar_scope>.size),
      (handles.scope.profile != nil) != (handles.scope.private_session != nil),
      (windowID == nil) == (handles.window == nil),
      (tabID == nil) == (handles.tab == nil),
      (windowID == nil) == (tabID == nil)
    else { throw ShaarEngineError.invalidEvent("site-data native scope is invalid") }
    if operation == .siteCookiesClear && (handles.window == nil || handles.tab == nil) {
      throw ShaarEngineError.invalidEvent("selected-cookie clear requires tab handles")
    }
    let requestID = requestIDs.take()
    return try await withCheckedThrowingContinuation { continuation in
      let box = ShaarSiteDataReplyBox(requestID: requestID, continuation: continuation)
      let replyContext = Unmanaged.passRetained(box).toOpaque()
      var immediateError = shaar_error(
        size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK, platform_code: 0,
        message: shaar_bytes(data: nil, size: 0))
      let status = arguments.withUnsafeBytes { raw -> UInt32 in
        let bytes = raw.bindMemory(to: CChar.self)
        var nativeScope = handles.scope
        return shaar_navigation_submit_invoke(
          submitSymbol, handles.engine, &nativeScope, handles.window, handles.tab,
          operation.rawValue,
          shaar_bytes(data: bytes.baseAddress, size: bytes.count), requestID,
          shaarSiteDataReply, replyContext, &immediateError)
      }
      guard status == ShaarStatusCode.ok.rawValue else {
        Unmanaged<ShaarSiteDataReplyBox>.fromOpaque(replyContext).release()
        let message =
          (try? String(decoding: copySiteDataBytes(immediateError.message), as: UTF8.self)) ?? ""
        do {
          try ShaarStatusCode.decode(
            status, platformCode: immediateError.platform_code, message: message)
          continuation.resume(throwing: ShaarEngineError.invalidStatusCode(status))
        } catch { continuation.resume(throwing: error) }
        return
      }
    }
  }
}
