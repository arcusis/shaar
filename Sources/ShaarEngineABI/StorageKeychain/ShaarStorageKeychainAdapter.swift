// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarStorageKeychainIdentity: String, Equatable, Sendable {
  case shaar
}

/// Transport binds the profile UUID to a live Shaar profile handle before
/// submitting. The status response contains identity metadata only, never a
/// keychain value or cookie/password plaintext.
public protocol ShaarStorageKeychainTransport: Sendable {
  func submitStorageKeychain(
    profileID: UUID,
    operation: UInt32,
    arguments: Data
  ) async throws -> Data
}

public enum ShaarStorageKeychainError: Error, Equatable, Sendable {
  case malformedResponse
}

public struct ShaarStorageKeychainAdapter: Sendable {
  public static let identityOperation: UInt32 = 1400

  private let transport: any ShaarStorageKeychainTransport

  public init(transport: any ShaarStorageKeychainTransport) {
    self.transport = transport
  }

  /// The Ardia implementation remains selected in shipping builds. Callers
  /// receive this adapter only when the existing choice selects Shaar.
  public static func selected(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarStorageKeychainTransport
  ) -> Self? {
    guard implementation == .shaar else { return nil }
    return Self(transport: transport)
  }

  public func configuredIdentity(for profileID: UUID) async throws
    -> ShaarStorageKeychainIdentity
  {
    let arguments = Data(#"{"schemaVersion":1}"#.utf8)
    let data = try await transport.submitStorageKeychain(
      profileID: profileID, operation: Self.identityOperation, arguments: arguments)
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schemaVersion", "identity"]),
      let version = object["schemaVersion"] as? Int, version == 1,
      let name = object["identity"] as? String,
      let identity = ShaarStorageKeychainIdentity(rawValue: name)
    else { throw ShaarStorageKeychainError.malformedResponse }
    return identity
  }
}
