// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import ShaarStorageKeychainABIC

/// A regular profile's already-open native scope. The resolver owns this
/// engine/profile mapping and must never fall back to another profile.
public struct ShaarStorageKeychainNativeProfile: @unchecked Sendable {
  public let engine: OpaquePointer
  public let scope: shaar_scope

  public init(engine: OpaquePointer, scope: shaar_scope) {
    self.engine = engine
    self.scope = scope
  }
}

public protocol ShaarStorageKeychainProfileResolving: Sendable {
  func resolve(profileID: UUID) async throws -> ShaarStorageKeychainNativeProfile
}

private final class StorageKeychainRequestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var next: UInt64 = 0x1400_0000_0000_0001

  func take() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let requestID = next
    next &+= 1
    if next == 0 { next = 0x1400_0000_0000_0001 }
    return requestID
  }
}

private final class StorageKeychainReplyBox: @unchecked Sendable {
  let requestID: UInt64
  let continuation: CheckedContinuation<Data, Error>

  init(requestID: UInt64, continuation: CheckedContinuation<Data, Error>) {
    self.requestID = requestID
    self.continuation = continuation
  }
}

private func copyStorageKeychainBytes(_ bytes: shaar_bytes) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid storage-keychain byte slice")
  }
  guard bytes.size > 0, let data = bytes.data else { return Data() }
  return Data(bytes: data, count: bytes.size)
}

private let storageKeychainReply: shaar_reply_fn = { context, result in
  guard let context else { return }
  let box = Unmanaged<StorageKeychainReplyBox>.fromOpaque(context).takeRetainedValue()
  guard let result else {
    box.continuation.resume(
      throwing: ShaarEngineError.invalidEvent("missing storage-keychain result"))
    return
  }
  do {
    let result = result.pointee
    guard result.size >= UInt32(MemoryLayout<shaar_result>.size),
      result.request_id == box.requestID
    else {
      throw ShaarEngineError.invalidEvent("storage-keychain result does not match request")
    }
    guard result.error.size >= UInt32(MemoryLayout<shaar_error>.size) else {
      throw ShaarEngineError.invalidEvent("short storage-keychain error")
    }
    let message = String(
      decoding: try copyStorageKeychainBytes(result.error.message), as: UTF8.self)
    try ShaarStatusCode.decode(
      UInt32(result.error.code.rawValue), platformCode: result.error.platform_code,
      message: message)
    let payload = try copyStorageKeychainBytes(result.payload_json)
    guard !payload.isEmpty else {
      throw ShaarEngineError.invalidEvent("empty storage-keychain result")
    }
    box.continuation.resume(returning: payload)
  } catch {
    box.continuation.resume(throwing: error)
  }
}

/// Concrete profile-only `shaar_submit` transport. It always submits a regular
/// profile scope with null window/tab handles, as required by this operation.
public struct ShaarStorageKeychainABITransport: ShaarStorageKeychainTransport,
  @unchecked Sendable
{
  private let submitSymbol: UnsafeRawPointer
  private let profileResolver: any ShaarStorageKeychainProfileResolving
  private let requestIDs = StorageKeychainRequestIDs()

  public init(
    resolver: ShaarSymbolResolving,
    profileResolver: any ShaarStorageKeychainProfileResolving
  ) throws {
    guard let submitSymbol = resolver.symbol(named: "shaar_submit") else {
      throw ShaarEngineError.missingSymbol("shaar_submit")
    }
    self.submitSymbol = submitSymbol
    self.profileResolver = profileResolver
  }

  public func submitStorageKeychain(
    profileID: UUID,
    operation: UInt32,
    arguments: Data
  ) async throws -> Data {
    guard operation == ShaarStorageKeychainAdapter.identityOperation else {
      throw ShaarEngineError.invalidEvent("unsupported storage-keychain operation")
    }
    let native = try await profileResolver.resolve(profileID: profileID)
    let scope = native.scope
    guard scope.size >= UInt32(MemoryLayout<shaar_scope>.size),
      scope.profile != nil, scope.private_session == nil
    else {
      throw ShaarEngineError.invalidEvent("storage-keychain requires a regular profile")
    }

    let requestID = requestIDs.take()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      let box = StorageKeychainReplyBox(requestID: requestID, continuation: continuation)
      let replyContext = Unmanaged.passRetained(box).toOpaque()
      var immediateError = shaar_error(
        size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
        platform_code: 0, message: shaar_bytes(data: nil, size: 0))
      let status = arguments.withUnsafeBytes { rawBuffer -> UInt32 in
        let bytes = rawBuffer.bindMemory(to: CChar.self)
        var nativeScope = scope
        return shaar_storage_keychain_submit_invoke(
          submitSymbol, native.engine, &nativeScope, operation,
          shaar_bytes(data: bytes.baseAddress, size: bytes.count), requestID,
          storageKeychainReply, replyContext, &immediateError)
      }
      if status != 0 {
        Unmanaged<StorageKeychainReplyBox>.fromOpaque(replyContext).release()
        guard immediateError.size >= UInt32(MemoryLayout<shaar_error>.size) else {
          continuation.resume(
            throwing: ShaarEngineError.invalidEvent("short storage-keychain error"))
          return
        }
        let message =
          (try? String(
            decoding: copyStorageKeychainBytes(immediateError.message), as: UTF8.self)) ?? ""
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

extension ShaarEngineLoader {
  /// Callers obtain the status adapter from the Shaar loader.
  public func makeStorageKeychainAdapter(
    profileResolver: any ShaarStorageKeychainProfileResolving
  ) throws -> ShaarStorageKeychainAdapter? {
    guard implementation == .shaar else { return nil }
    let transport = try ShaarStorageKeychainABITransport(
      resolver: self, profileResolver: profileResolver)
    return ShaarStorageKeychainAdapter.selected(
      implementation: implementation, transport: transport)
  }
}
