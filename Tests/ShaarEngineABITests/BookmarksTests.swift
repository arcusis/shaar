// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@MainActor private final class FakeBookmarksTransport: ShaarBookmarksTransport {
  private(set) var calls: [(ShaarBookmarkOperation, Data)] = []
  var response: Data

  init(_ response: [String: Any]) {
    self.response = try! JSONSerialization.data(withJSONObject: response)
  }

  func submit(
    operation: ShaarBookmarkOperation,
    arguments: Data,
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  ) {
    calls.append((operation, arguments))
    completion(.success(response))
  }
}

@Suite("Shaar bookmarks adapter")
struct BookmarksAdapterTests {
  @Test @MainActor func shippingDefaultUsesShaarTransport() throws {
    let shaar = FakeBookmarksTransport(["schemaVersion": 1, "bar": [:], "other": [:]])
    let adapter = ShaarBookmarksAdapter(shaar: shaar)
    var receivedTree = false
    adapter.tree { result in receivedTree = (try? result.get()["bar"] as? [String: Any]) != nil }
    #expect(receivedTree)
    #expect(shaar.calls.map(\.0) == [.tree])
  }

  @Test @MainActor func selectedShaarTransportReceivesVersionedOperationAndValidatesReply() throws {
    let shaar = FakeBookmarksTransport([
      "schemaVersion": 1, "applied": 1, "skipped": 0, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(shaar: shaar)
    var succeeded = false
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) {
      succeeded = (try? $0.get()) != nil
    }
    #expect(succeeded)
    #expect(shaar.calls.count == 1)
    let (operation, bytes) = try #require(shaar.calls.first)
    #expect(operation == .apply)
    let payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
    #expect((payload["ops"] as? [[String: Any]])?.first?["op"] as? String == "remove")
  }

  @Test @MainActor func selectedShaarTreeSendsSchemaVersion() throws {
    let transport = FakeBookmarksTransport(["schemaVersion": 1, "bar": [:], "other": [:]])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    adapter.tree { _ in }

    let (operation, bytes) = try #require(transport.calls.first)
    #expect(operation == .tree)
    let payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
  }

  @Test @MainActor func selectedShaarWatchConfirmsBothStates() throws {
    let transport = FakeBookmarksTransport(["schemaVersion": 1, "watching": true])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    var enabled: Result<Void, Error>?
    adapter.watch(enabled: true) { enabled = $0 }
    #expect((try? enabled?.get()) != nil)

    transport.response = try JSONSerialization.data(
      withJSONObject: ["schemaVersion": 1, "watching": false])
    var disabled: Result<Void, Error>?
    adapter.watch(enabled: false) { disabled = $0 }
    #expect((try? disabled?.get()) != nil)
    #expect(transport.calls.map { $0.0 } == [.watch, .watch])
    let arguments = try transport.calls.map { call in
      try #require(JSONSerialization.jsonObject(with: call.1) as? [String: Any])
    }
    #expect(arguments[0]["schemaVersion"] as? Int == 1)
    #expect(arguments[0]["enabled"] as? Bool == true)
    #expect(arguments[1]["enabled"] as? Bool == false)
  }

  @Test @MainActor func watchRejectsNumericConfirmation() {
    let transport = FakeBookmarksTransport(["schemaVersion": 1, "watching": 1])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    var rejected = false
    adapter.watch(enabled: true) { result in
      if case .failure(ShaarBookmarksAdapterError.watchNotConfirmed) = result {
        rejected = true
      }
    }
    #expect(rejected)
  }

  @Test @MainActor func selectedShaarApplyRejectsUnconfirmedMutation() {
    let transport = FakeBookmarksTransport([
      "schemaVersion": 1, "applied": 0, "skipped": 0, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    var rejected = false
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) {
      if case .failure(ShaarBookmarksAdapterError.mutationNotConfirmed) = $0 {
        rejected = true
      }
    }
    #expect(rejected)
  }

  @Test @MainActor func mutationRejectsBooleanConfirmationCounts() {
    let transport = FakeBookmarksTransport([
      "schemaVersion": 1, "applied": true, "skipped": false, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    var rejected = false
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) {
      if case .failure(ShaarBookmarksAdapterError.mutationNotConfirmed) = $0 {
        rejected = true
      }
    }
    #expect(rejected)
  }

  @Test @MainActor func mutationRejectsBooleanSchemaVersion() {
    let transport = FakeBookmarksTransport([
      "schemaVersion": true, "applied": 1, "skipped": 0, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(shaar: transport)
    var rejected = false
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) {
      if case .failure(ShaarBookmarksAdapterError.mutationNotConfirmed) = $0 {
        rejected = true
      }
    }
    #expect(rejected)
  }

  @Test @MainActor func shaarTreeRejectsMalformedPayload() {
    let fake = FakeBookmarksTransport(["schemaVersion": 1, "bar": []])
    let adapter = ShaarBookmarksAdapter(shaar: fake)
    var rejected = false
    adapter.tree { result in
      if case .failure(ShaarBookmarksAdapterError.invalidTree) = result { rejected = true }
    }
    #expect(rejected)
  }
}
