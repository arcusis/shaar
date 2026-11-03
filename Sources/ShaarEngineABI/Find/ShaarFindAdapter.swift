// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarFindOperation: UInt32, Sendable {
  case find = 900
  case stop = 901
}

public struct ShaarFindScope: Equatable, Sendable {
  public let profileID: String
  public let sessionID: String?

  public init(profileID: String, sessionID: String? = nil) {
    self.profileID = profileID
    self.sessionID = sessionID
  }
}

public struct ShaarFindRequest: Equatable, Sendable {
  public let requestID: UInt64
  public let operation: ShaarFindOperation
  public let scope: ShaarFindScope
  public let windowID: String
  public let tabID: String
  public let payload: Data
}

public struct ShaarFindUpdate: Equatable, Sendable {
  public let requestID: UInt64
  public let matchCount: Int
  public let activeMatch: Int
  public let isFinal: Bool
}

@MainActor public protocol ShaarFindTransport {
  func submit(
    _ request: ShaarFindRequest,
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  )
  func setEventHandler(_ handler: @escaping @MainActor (ShaarCopiedEvent) -> Void)
}

@MainActor public protocol ArdiaFindBackend {
  func find(
    query: String, forward: Bool,
    profileID: String, tabID: String, requestToken: String,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  )
  func stop(
    clearSelection: Bool, profileID: String, tabID: String,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  )
}

@MainActor public final class ShaarFindAdapter {
  private static var nextEngineRequestID: UInt64 = 1
  public let implementation: ShaarEngineImplementation
  public var onEvent: (@MainActor (ShaarCopiedEvent) -> Void)?
  private let ardia: any ArdiaFindBackend
  private let shaar: any ShaarFindTransport

  public init(
    implementation: ShaarEngineImplementation = .shippingDefault,
    ardia: any ArdiaFindBackend,
    shaar: any ShaarFindTransport
  ) {
    self.implementation = implementation
    self.ardia = ardia
    self.shaar = shaar
    shaar.setEventHandler { [weak self] event in self?.onEvent?(event) }
  }

  @discardableResult public func find(
    query: String, forward: Bool, scope: ShaarFindScope, windowID: String,
    tabID: String, requestToken: String = "",
    completion: @escaping @MainActor (Result<UInt64, Error>) -> Void
  ) -> UInt64? {
    guard implementation == .shaar else {
      ardia.find(
        query: query, forward: forward, profileID: scope.profileID,
        tabID: tabID, requestToken: requestToken
      ) { result in
        completion(result.map { 0 })
      }
      return nil
    }
    let requestID = allocateRequestID()
    submit(
      requestID, .find, fields: ["query": query, "forward": forward], scope: scope,
      windowID: windowID, tabID: tabID
    ) { result in
      completion(result.map { _ in requestID })
    }
    return requestID
  }

  @discardableResult public func stop(
    clearSelection: Bool, scope: ShaarFindScope, windowID: String, tabID: String,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) -> UInt64? {
    guard implementation == .shaar else {
      ardia.stop(
        clearSelection: clearSelection, profileID: scope.profileID, tabID: tabID,
        completion: completion)
      return nil
    }
    let requestID = allocateRequestID()
    submit(
      requestID, .stop, fields: ["selection": clearSelection ? "clear" : "keep"],
      scope: scope, windowID: windowID, tabID: tabID
    ) { result in completion(result.map { _ in () }) }
    return requestID
  }

  /// Decodes an event only when its exact ownership and caller token match.
  public func decode(
    _ event: ShaarCopiedEvent, expectedScope: ShaarFindScope,
    expectedWindowID: String, expectedTabID: String, expectedRequestID: UInt64
  ) -> ShaarFindUpdate? {
    guard event.kind == 7,
      String(decoding: event.profileID, as: UTF8.self) == expectedScope.profileID,
      String(decoding: event.sessionID, as: UTF8.self) == (expectedScope.sessionID ?? ""),
      String(decoding: event.windowID, as: UTF8.self) == expectedWindowID,
      String(decoding: event.tabID, as: UTF8.self) == expectedTabID,
      let object = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      object["kind"] as? String == "result",
      object["schemaVersion"] as? Int == 1,
      let request = object["requestID"] as? String,
      UInt64(request) == expectedRequestID,
      let count = object["matchCount"] as? Int,
      let active = object["activeMatch"] as? Int,
      let final = object["final"] as? Bool
    else { return nil }
    return ShaarFindUpdate(
      requestID: expectedRequestID, matchCount: count,
      activeMatch: active, isFinal: final)
  }

  private func allocateRequestID() -> UInt64 {
    let value = Self.nextEngineRequestID
    Self.nextEngineRequestID &+= 1
    if Self.nextEngineRequestID == 0 { Self.nextEngineRequestID = 1 }
    return value
  }

  private func submit(
    _ requestID: UInt64, _ operation: ShaarFindOperation, fields: [String: Any],
    scope: ShaarFindScope,
    windowID: String, tabID: String,
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  ) {
    var envelope = fields
    envelope["schemaVersion"] = 1
    do {
      let payload = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
      shaar.submit(
        ShaarFindRequest(
          requestID: requestID, operation: operation, scope: scope, windowID: windowID,
          tabID: tabID, payload: payload), completion: completion)
    } catch { completion(.failure(error)) }
  }
}
