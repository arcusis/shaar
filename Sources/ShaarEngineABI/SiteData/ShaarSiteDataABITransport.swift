// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC

private final class SiteDataRequestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var next: UInt64 = 0x1201_0000_0000_0001

  func take() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let value = next
    next &+= 1
    if next == 0 { next = 0x1201_0000_0000_0001 }
    return value
  }
}

private final class SiteDataReplyBox: @unchecked Sendable {
  let requestID: UInt64
  let continuation: CheckedContinuation<Data, Error>

  init(requestID: UInt64, continuation: CheckedContinuation<Data, Error>) {
    self.requestID = requestID
    self.continuation = continuation
  }
}

private func copySiteDataBytes(_ bytes: shaar_bytes) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid site-data byte slice")
  }
  guard bytes.size > 0, let data = bytes.data else { return Data() }
  return Data(bytes: data, count: bytes.size)
}

private let siteDataReply: shaar_reply_fn = { context, result in
  guard let context else { return }
  let box = Unmanaged<SiteDataReplyBox>.fromOpaque(context).takeRetainedValue()
  guard let result else {
    box.continuation.resume(throwing: ShaarEngineError.invalidEvent("missing site-data result"))
    return
  }
  do {
    let result = result.pointee
    guard result.size >= UInt32(MemoryLayout<shaar_result>.size),
      result.request_id == box.requestID
    else { throw ShaarEngineError.invalidEvent("site-data result does not match request") }
    let message = String(decoding: try copySiteDataBytes(result.error.message), as: UTF8.self)
    try ShaarStatusCode.decode(
      UInt32(result.error.code.rawValue), platformCode: result.error.platform_code,
      message: message)
    let payload = try copySiteDataBytes(result.payload_json)
    guard !payload.isEmpty else { throw ShaarEngineError.invalidEvent("empty site-data result") }
    box.continuation.resume(returning: payload)
  } catch {
    box.continuation.resume(throwing: error)
  }
}

/// Resolves every operation from the exact regular profile selected in Settings.
/// The native layer rechecks the opaque scope; no tab or private session is supplied.
public struct ShaarSiteDataABITransport: ShaarSiteDataTransport, @unchecked Sendable {
  private let submitSymbol: UnsafeRawPointer
  private let profileResolver: any ShaarStorageKeychainProfileResolving
  private let requestIDs = SiteDataRequestIDs()

  public init(
    resolver: ShaarSymbolResolving,
    profileResolver: any ShaarStorageKeychainProfileResolving
  ) throws {
    guard let symbol = resolver.symbol(named: "shaar_submit") else {
      throw ShaarEngineError.missingSymbol("shaar_submit")
    }
    submitSymbol = symbol
    self.profileResolver = profileResolver
  }

  public func submit(
    profileID: UUID, operation: ShaarSiteDataOperation, arguments: Data
  ) async throws -> Data {
    let native = try await profileResolver.resolve(profileID: profileID)
    let scope = native.scope
    guard scope.size >= UInt32(MemoryLayout<shaar_scope>.size),
      scope.profile != nil, scope.private_session == nil
    else { throw ShaarSiteDataError.wrongProfile }

    let requestID = requestIDs.take()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      let box = SiteDataReplyBox(requestID: requestID, continuation: continuation)
      let replyContext = Unmanaged.passRetained(box).toOpaque()
      var immediateError = shaar_error(
        size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK,
        platform_code: 0, message: shaar_bytes(data: nil, size: 0))
      let status = arguments.withUnsafeBytes { rawBuffer -> UInt32 in
        let bytes = rawBuffer.bindMemory(to: CChar.self)
        var nativeScope = scope
        return shaar_navigation_submit_invoke(
          submitSymbol, native.engine, &nativeScope, nil, nil, operation.rawValue,
          shaar_bytes(data: bytes.baseAddress, size: bytes.count), requestID,
          siteDataReply, replyContext, &immediateError)
      }
      if status != UInt32(SHAAR_OK.rawValue) {
        Unmanaged<SiteDataReplyBox>.fromOpaque(replyContext).release()
        let message =
          (try? String(decoding: copySiteDataBytes(immediateError.message), as: UTF8.self)) ?? ""
        do {
          try ShaarStatusCode.decode(
            status, platformCode: immediateError.platform_code, message: message)
          continuation.resume(throwing: ShaarEngineError.invalidStatusCode(status))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

extension ShaarEngineTransport {
  public func siteDataAdapter(
    profileID: UUID, profileResolver: any ShaarStorageKeychainProfileResolving
  ) throws -> ShaarSiteDataAdapter {
    let transport = try ShaarSiteDataABITransport(
      resolver: self, profileResolver: profileResolver)
    return ShaarSiteDataAdapter(profileID: profileID, implementation: .shaar, transport: transport)
  }
}
