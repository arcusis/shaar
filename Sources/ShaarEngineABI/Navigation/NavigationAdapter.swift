// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation
import ShaarEngineABIC

private func navigationInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(number.stringValue) ?? Int(exactly: number.doubleValue)
}

private func navigationGeneration(_ value: Any?) -> UInt64? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return UInt64(number.stringValue) ?? UInt64(exactly: number.doubleValue)
}

private func navigationBoolean(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

public enum ShaarNavigationOperation: UInt32, Sendable {
  case navigate = 300
  case go = 301
  case reload = 302
  case stop = 303
}

public struct ShaarNavigationScope: Equatable, Sendable {
  public let profileID: String
  public let sessionID: String?

  public init(profileID: String, sessionID: String? = nil) {
    self.profileID = profileID
    self.sessionID = sessionID
  }
}

public struct ShaarNavigationRequest: Equatable, Sendable {
  public let operation: ShaarNavigationOperation
  public let scope: ShaarNavigationScope
  public let windowID: String
  public let tabID: String
  public let payload: Data
}

public protocol ShaarNavigationSubmitting: Sendable {
  /// A production transport copies the request into `shaar_submit` and returns
  /// its caller-owned ID. Completion is always asynchronous after acceptance.
  func submit(
    _ request: ShaarNavigationRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64
}

public struct ShaarABINativeHandles: @unchecked Sendable {
  public let engine: OpaquePointer
  public let scope: shaar_scope
  public let window: OpaquePointer
  public let tab: OpaquePointer

  public init(
    engine: OpaquePointer, scope: shaar_scope, window: OpaquePointer, tab: OpaquePointer
  ) {
    self.engine = engine
    self.scope = scope
    self.window = window
    self.tab = tab
  }
}

public protocol ShaarNavigationHandleResolving: Sendable {
  /// Resolve stable IDs only within the supplied exact regular/private scope.
  func resolve(
    scope: ShaarNavigationScope, windowID: String, tabID: String
  ) throws -> ShaarABINativeHandles
}

private final class ShaarNavigationReplyBox: @unchecked Sendable {
  let expectedRequestID: UInt64
  let completion: @Sendable (Result<Data, ShaarEngineError>) -> Void
  init(
    requestID: UInt64,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) {
    expectedRequestID = requestID
    self.completion = completion
  }
}

private func copyABISlice(_ bytes: shaar_bytes) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid ABI byte slice")
  }
  guard bytes.size > 0, let pointer = bytes.data else { return Data() }
  return Data(bytes: pointer, count: bytes.size)
}

private let shaarNavigationReply: shaar_reply_fn = { context, result in
  guard let context else { return }
  let box = Unmanaged<ShaarNavigationReplyBox>.fromOpaque(context).takeRetainedValue()
  guard let result else {
    box.completion(.failure(.invalidEvent("missing navigation result")))
    return
  }
  do {
    let result = result.pointee
    guard result.size >= UInt32(MemoryLayout<shaar_result>.size) else {
      throw ShaarEngineError.invalidEvent("short navigation result")
    }
    guard result.request_id == box.expectedRequestID else {
      throw ShaarEngineError.invalidEvent("navigation result request ID mismatch")
    }
    guard result.error.size >= UInt32(MemoryLayout<shaar_error>.size) else {
      throw ShaarEngineError.invalidEvent("short navigation error")
    }
    try ShaarStatusCode.decode(
      UInt32(result.error.code.rawValue), platformCode: result.error.platform_code,
      message: String(decoding: try copyABISlice(result.error.message), as: UTF8.self))
    let payload = try copyABISlice(result.payload_json)
    guard !payload.isEmpty,
      let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      navigationInteger(object["schemaVersion"]) == 1
    else { throw ShaarEngineError.invalidEvent("invalid navigation result payload") }
    box.completion(.success(payload))
  } catch let error as ShaarEngineError {
    box.completion(.failure(error))
  } catch {
    box.completion(.failure(.invalidEvent("invalid navigation result bytes")))
  }
}

private final class ShaarNavigationRequestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var next: UInt64 = 1

  func take() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let result = next
    next &+= 1
    if next == 0 { next = 1 }
    return result
  }
}

/// Concrete `shaar_submit` transport. The handle resolver owns the engine's
/// ID-to-opaque-handle maps; this adapter never infers scope from a tab.
public struct ShaarNavigationABITransport: ShaarNavigationSubmitting, @unchecked Sendable {
  private let submitSymbol: UnsafeRawPointer
  private let handleResolver: any ShaarNavigationHandleResolving
  private let requestIDs: ShaarNavigationRequestIDs

  public init(
    resolver: ShaarSymbolResolving,
    handleResolver: any ShaarNavigationHandleResolving
  ) throws {
    guard let symbol = resolver.symbol(named: "shaar_submit") else {
      throw ShaarEngineError.missingSymbol("shaar_submit")
    }
    submitSymbol = symbol
    self.handleResolver = handleResolver
    requestIDs = ShaarNavigationRequestIDs()
  }

  public func submit(
    _ request: ShaarNavigationRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    let handles = try handleResolver.resolve(
      scope: request.scope, windowID: request.windowID, tabID: request.tabID)
    let hasRegularProfile = handles.scope.profile != nil
    let hasPrivateSession = handles.scope.private_session != nil
    guard handles.scope.size >= UInt32(MemoryLayout<shaar_scope>.size),
      hasRegularProfile != hasPrivateSession
    else { throw ShaarEngineError.invalidEvent("native navigation scope is invalid") }
    let requestID = requestIDs.take()
    let replyBox = ShaarNavigationReplyBox(requestID: requestID, completion: completion)
    let replyContext = Unmanaged.passRetained(replyBox).toOpaque()
    var immediateError = shaar_error(
      size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
      platform_code: 0,
      message: shaar_bytes(data: nil, size: 0))
    let status = request.payload.withUnsafeBytes { rawBuffer -> UInt32 in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      var scope = handles.scope
      return shaar_navigation_submit_invoke(
        submitSymbol, handles.engine, &scope, handles.window, handles.tab,
        request.operation.rawValue,
        shaar_bytes(data: buffer.baseAddress, size: buffer.count), requestID,
        shaarNavigationReply, replyContext, &immediateError)
    }
    guard status == ShaarStatusCode.ok.rawValue else {
      Unmanaged<ShaarNavigationReplyBox>.fromOpaque(replyContext).release()
      guard immediateError.size >= UInt32(MemoryLayout<shaar_error>.size) else {
        throw ShaarEngineError.invalidEvent("short navigation immediate error")
      }
      let message =
        (try? String(decoding: copyABISlice(immediateError.message), as: UTF8.self)) ?? ""
      try ShaarStatusCode.decode(
        status, platformCode: immediateError.platform_code, message: message)
      throw ShaarEngineError.invalidStatusCode(status)
    }
    return requestID
  }
}

extension ShaarEngineLoader {
  /// Create the navigation ABI transport only when this loader selected Shaar.
  /// Returning `nil` indicates the native capability is unavailable.
  public func makeNavigationTransport(
    handleResolver: any ShaarNavigationHandleResolving
  ) throws -> ShaarNavigationABITransport? {
    guard implementation == .shaar else { return nil }
    return try ShaarNavigationABITransport(resolver: self, handleResolver: handleResolver)
  }
}

public enum ShaarNavigationCommand: Equatable, Sendable {
  case navigate(url: String, userInitiated: Bool)
  case goBack
  case goForward
  case reload
  case reloadBypassingCache
  case stop

  fileprivate var operation: ShaarNavigationOperation {
    switch self {
    case .navigate: .navigate
    case .goBack, .goForward: .go
    case .reload, .reloadBypassingCache: .reload
    case .stop: .stop
    }
  }

  fileprivate var arguments: [String: Any] {
    switch self {
    case .navigate(let url, let userInitiated):
      ["schemaVersion": 1, "url": url, "userInitiated": userInitiated]
    case .goBack: ["schemaVersion": 1, "direction": "back"]
    case .goForward: ["schemaVersion": 1, "direction": "forward"]
    case .reload: ["schemaVersion": 1, "mode": "normal"]
    case .reloadBypassingCache: ["schemaVersion": 1, "mode": "bypass_cache"]
    case .stop: ["schemaVersion": 1]
    }
  }
}

/// Thin command adapter. Callers
/// only instantiate this adapter when the selected engine is `.shaar`.
public struct ShaarNavigationAdapter: Sendable {
  private let transport: any ShaarNavigationSubmitting

  public init?(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarNavigationSubmitting
  ) {
    guard implementation == .shaar else { return nil }
    self.transport = transport
  }

  @discardableResult
  public func submit(
    _ command: ShaarNavigationCommand,
    scope: ShaarNavigationScope,
    windowID: String,
    tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard !scope.profileID.isEmpty,
      let sessionIsValid = Optional(scope.sessionID == nil || !(scope.sessionID ?? "").isEmpty),
      sessionIsValid, !windowID.isEmpty, !tabID.isEmpty
    else { throw ShaarEngineError.invalidEvent("navigation ownership is incomplete") }

    let payload = command.arguments
    try Self.validateKeys(payload, for: command)
    let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let request = ShaarNavigationRequest(
      operation: command.operation, scope: scope, windowID: windowID, tabID: tabID,
      payload: encoded)
    return try transport.submit(request, completion: completion)
  }

  private static func validateKeys(_ payload: [String: Any], for command: ShaarNavigationCommand)
    throws
  {
    let expected: Set<String>
    switch command {
    case .navigate: expected = ["schemaVersion", "url", "userInitiated"]
    case .goBack, .goForward: expected = ["schemaVersion", "direction"]
    case .reload, .reloadBypassingCache: expected = ["schemaVersion", "mode"]
    case .stop: expected = ["schemaVersion"]
    }
    guard Set(payload.keys) == expected else {
      throw ShaarEngineError.invalidEvent("invalid navigation request fields")
    }
  }
}

public struct ShaarNavigationSnapshot: Equatable, Sendable {
  public enum Phase: String, Sendable {
    case started, committed, finished, failed, stopped, state
  }

  public struct Failure: Equatable, Sendable {
    public let netError: Int
    public let isMainFrame: Bool
    public let descriptionCode: String
  }

  public let navigationID: String
  public let generation: UInt64
  public let phase: Phase
  public let url: String?
  public let title: String?
  public let loading: Bool
  public let canGoBack: Bool
  public let canGoForward: Bool
  public let sameDocument: Bool
  public let failure: Failure?

  public static func decode(_ bytes: Data) throws -> Self {
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw ShaarEngineError.invalidEvent("navigation payload is not an object")
    }
    let required: Set<String> = [
      "kind", "schemaVersion", "phase", "navigationID", "generation", "url", "title",
      "loading", "canGoBack", "canGoForward", "sameDocument",
    ]
    let allowed = required.union(["failure"])
    guard Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)),
      object["kind"] as? String == "navigation",
      navigationInteger(object["schemaVersion"]) == 1,
      let phaseName = object["phase"] as? String, let phase = Phase(rawValue: phaseName),
      let navigationID = object["navigationID"] as? String, !navigationID.isEmpty,
      let generation = navigationGeneration(object["generation"]), generation > 0,
      let loading = navigationBoolean(object["loading"]),
      let canGoBack = navigationBoolean(object["canGoBack"]),
      let canGoForward = navigationBoolean(object["canGoForward"]),
      let sameDocument = navigationBoolean(object["sameDocument"]),
      object["url"] is NSNull || object["url"] is String,
      object["title"] is NSNull || object["title"] is String
    else { throw ShaarEngineError.invalidEvent("invalid navigation snapshot") }

    let decodedFailure: Failure?
    if let failure = object["failure"] {
      guard let details = failure as? [String: Any],
        Set(details.keys) == ["netError", "isMainFrame", "descriptionCode"],
        let netError = navigationInteger(details["netError"]),
        let isMainFrame = navigationBoolean(details["isMainFrame"]),
        let descriptionCode = details["descriptionCode"] as? String
      else { throw ShaarEngineError.invalidEvent("invalid navigation failure") }
      decodedFailure = Failure(
        netError: netError, isMainFrame: isMainFrame, descriptionCode: descriptionCode)
    } else {
      decodedFailure = nil
    }

    let rawURL = object["url"] as? String
    return Self(
      navigationID: navigationID, generation: generation, phase: phase,
      url: rawURL.map(Self.redactCredentials), title: object["title"] as? String,
      loading: loading, canGoBack: canGoBack, canGoForward: canGoForward,
      sameDocument: sameDocument, failure: decodedFailure)
  }

  private static func redactCredentials(_ value: String) -> String {
    guard var components = URLComponents(string: value) else { return value }
    components.user = nil
    components.password = nil
    return components.string ?? value
  }
}

/// Rejects delayed callbacks from an earlier navigation or a closed/reused tab.
public struct ShaarNavigationGeneration: Sendable {
  private var lastGeneration: UInt64 = 0
  private var isOpen = true

  public init() {}

  public mutating func accept(_ snapshot: ShaarNavigationSnapshot) -> Bool {
    guard isOpen, snapshot.generation > lastGeneration else { return false }
    lastGeneration = snapshot.generation
    return true
  }

  public mutating func close() { isOpen = false }
}
