// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeStorageKeychainTransport: ShaarStorageKeychainTransport {
  struct Call: Equatable, Sendable {
    let profileID: UUID
    let operation: UInt32
    let arguments: Data
  }

  private let reply: Data
  private(set) var calls: [Call] = []

  init(reply: String) { self.reply = Data(reply.utf8) }

  func submitStorageKeychain(
    profileID: UUID,
    operation: UInt32,
    arguments: Data
  ) async throws -> Data {
    calls.append(Call(profileID: profileID, operation: operation, arguments: arguments))
    return reply
  }
}

@Suite("Storage keychain")
struct StorageKeychainTests {
  @Test func shippingDefaultKeepsArdiaAndShaarUsesItsStatusRoute() async throws {
    let profile = UUID()
    let fake = FakeStorageKeychainTransport(
      reply: #"{"schemaVersion":1,"identity":"shaar"}"#)

    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(ShaarStorageKeychainAdapter.selected(transport: fake).map { _ in true } == nil)
    let adapter = try #require(
      ShaarStorageKeychainAdapter.selected(implementation: .shaar, transport: fake))
    #expect(try await adapter.configuredIdentity(for: profile) == .shaar)

    let calls = await fake.calls
    #expect(calls.count == 1)
    #expect(calls[0].profileID == profile)
    #expect(calls[0].operation == ShaarStorageKeychainAdapter.identityOperation)
    #expect(calls[0].arguments == Data(#"{"schemaVersion":1}"#.utf8))
  }

  @Test func rejectsUnknownIdentityAndSecretBearingFields() async {
    let profile = UUID()
    let unknown = ShaarStorageKeychainAdapter(
      transport: FakeStorageKeychainTransport(
        reply: #"{"schemaVersion":1,"identity":"ardia"}"#))
    await #expect(throws: ShaarStorageKeychainError.malformedResponse) {
      try await unknown.configuredIdentity(for: profile)
    }

    let secretField = ShaarStorageKeychainAdapter(
      transport: FakeStorageKeychainTransport(
        reply: #"{"schemaVersion":1,"identity":"shaar","password":"never"}"#))
    await #expect(throws: ShaarStorageKeychainError.malformedResponse) {
      try await secretField.configuredIdentity(for: profile)
    }
  }
}
