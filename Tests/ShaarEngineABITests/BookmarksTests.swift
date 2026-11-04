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

@MainActor private final class FakeArdiaBookmarks: ArdiaBookmarksBackend {
  private(set) var treeCalls = 0
  private(set) var applyCalls = 0
  private(set) var watchCalls = 0

  func tree(completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void) {
    treeCalls += 1
    completion(.success(["bar": [String: Any](), "other": [String: Any]()]))
  }

  func apply(
    _ operation: [String: Any],
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    applyCalls += 1
    completion(.success(()))
  }

  func watch(enabled: Bool, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
    watchCalls += 1
    completion(.success(()))
  }
}

@Suite("Shaar bookmarks adapter")
struct BookmarksAdapterTests {
  @Test @MainActor func shippingDefaultKeepsUsingArdiaFacade() throws {
    let ardia = FakeArdiaBookmarks()
    let shaar = FakeBookmarksTransport(["schemaVersion": 1, "bar": [:], "other": [:]])
    let adapter = ShaarBookmarksAdapter(ardia: ardia, shaar: shaar)
    var receivedTree = false
    adapter.tree { result in receivedTree = (try? result.get()["bar"] as? [String: Any]) != nil }
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) { _ in }
    adapter.watch(enabled: true) { _ in }
    #expect(receivedTree)
    #expect(ardia.treeCalls == 1)
    #expect(ardia.applyCalls == 1)
    #expect(ardia.watchCalls == 1)
    #expect(shaar.calls.isEmpty)
  }

  @Test @MainActor func selectedShaarTransportReceivesVersionedOperationAndValidatesReply() throws {
    let ardia = FakeArdiaBookmarks()
    let shaar = FakeBookmarksTransport([
      "schemaVersion": 1, "applied": 1, "skipped": 0, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(implementation: .shaar, ardia: ardia, shaar: shaar)
    var succeeded = false
    adapter.apply(["op": "remove", "id": "00000000-0000-4000-8000-000000000001"]) {
      succeeded = (try? $0.get()) != nil
    }
    #expect(succeeded)
    #expect(ardia.applyCalls == 0)
    #expect(shaar.calls.count == 1)
    let (operation, bytes) = try #require(shaar.calls.first)
    #expect(operation == .apply)
    let payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
    #expect((payload["ops"] as? [[String: Any]])?.first?["op"] as? String == "remove")
  }

  @Test @MainActor func selectedShaarTreeSendsSchemaVersion() throws {
    let transport = FakeBookmarksTransport(["schemaVersion": 1, "bar": [:], "other": [:]])
    let adapter = ShaarBookmarksAdapter(
      implementation: .shaar, ardia: FakeArdiaBookmarks(), shaar: transport)
    adapter.tree { _ in }

    let (operation, bytes) = try #require(transport.calls.first)
    #expect(operation == .tree)
    let payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
  }

  @Test @MainActor func selectedShaarWatchConfirmsBothStates() throws {
    let transport = FakeBookmarksTransport(["schemaVersion": 1, "watching": true])
    let adapter = ShaarBookmarksAdapter(
      implementation: .shaar, ardia: FakeArdiaBookmarks(), shaar: transport)
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

  @Test @MainActor func selectedShaarApplyRejectsUnconfirmedMutation() {
    let transport = FakeBookmarksTransport([
      "schemaVersion": 1, "applied": 0, "skipped": 0, "invalid": [Any](),
    ])
    let adapter = ShaarBookmarksAdapter(
      implementation: .shaar, ardia: FakeArdiaBookmarks(), shaar: transport)
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
    let adapter = ShaarBookmarksAdapter(
      implementation: .shaar, ardia: FakeArdiaBookmarks(), shaar: fake)
    var rejected = false
    adapter.tree { result in
      if case .failure(ShaarBookmarksAdapterError.invalidTree) = result { rejected = true }
    }
    #expect(rejected)
  }
}
