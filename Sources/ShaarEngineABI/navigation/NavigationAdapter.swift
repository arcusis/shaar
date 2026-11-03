// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

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

/// Thin command adapter. The Ardia path remains the shipping default; callers
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

  public let navigationID: String
  public let generation: UInt64
  public let phase: Phase
  public let url: String?
  public let title: String?
  public let loading: Bool
  public let canGoBack: Bool
  public let canGoForward: Bool
  public let sameDocument: Bool

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
      object["schemaVersion"] as? Int == 1,
      let phaseName = object["phase"] as? String, let phase = Phase(rawValue: phaseName),
      let navigationID = object["navigationID"] as? String,
      let generation = object["generation"] as? UInt64,
      let loading = object["loading"] as? Bool,
      let canGoBack = object["canGoBack"] as? Bool,
      let canGoForward = object["canGoForward"] as? Bool,
      let sameDocument = object["sameDocument"] as? Bool,
      object["url"] is NSNull || object["url"] is String,
      object["title"] is NSNull || object["title"] is String
    else { throw ShaarEngineError.invalidEvent("invalid navigation snapshot") }

    let rawURL = object["url"] as? String
    return Self(
      navigationID: navigationID, generation: generation, phase: phase,
      url: rawURL.map(Self.redactCredentials), title: object["title"] as? String,
      loading: loading, canGoBack: canGoBack, canGoForward: canGoForward,
      sameDocument: sameDocument)
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
