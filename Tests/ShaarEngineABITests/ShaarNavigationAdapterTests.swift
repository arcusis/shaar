// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private final class FakeNavigationEngine: ShaarNavigationSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: ShaarNavigationRequest?

  var request: ShaarNavigationRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }

  func submit(
    _ request: ShaarNavigationRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    lock.lock()
    storedRequest = request
    lock.unlock()
    Task { completion(.success(Data("{}".utf8))) }
    return 77
  }
}

@Suite("Shaar navigation adapter")
struct ShaarNavigationAdapterTests {
  @Test func commandUsesExactScopeAndVersionedPayload() throws {
    let fake = FakeNavigationEngine()
    let adapter = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake))
    let requestID = try adapter.submit(
      .navigate(url: "https://example.test/path", userInitiated: true),
      scope: ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })

    #expect(requestID == 77)
    #expect(fake.request?.operation == .navigate)
    #expect(
      fake.request?.scope == ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a"))
    #expect(fake.request?.windowID == "window-a")
    #expect(fake.request?.tabID == "tab-a")
    let request = try #require(fake.request)
    let payload = try #require(
      JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
    #expect(payload["url"] as? String == "https://example.test/path")
    #expect(payload["userInitiated"] as? Bool == true)
  }

  @Test(arguments: [
    (ShaarNavigationCommand.goBack, "back"),
    (.goForward, "forward"),
  ])
  func historyDirectionIsExplicit(command: ShaarNavigationCommand, direction: String) throws {
    let fake = FakeNavigationEngine()
    _ = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake)).submit(
      command, scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
      completion: { _ in })
    let request = try #require(fake.request)
    let payload = try #require(
      JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(payload["direction"] as? String == direction)
  }

  @Test func reloadModesAndStopHaveSeparateSchemas() throws {
    for (command, operation, fieldValue) in [
      (ShaarNavigationCommand.reload, ShaarNavigationOperation.reload, "normal"),
      (.reloadBypassingCache, .reload, "bypass_cache"),
      (.stop, .stop, ""),
    ] {
      let fake = FakeNavigationEngine()
      _ = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake)).submit(
        command, scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
        completion: { _ in })
      #expect(fake.request?.operation == operation)
      let request = try #require(fake.request)
      let payload = try #require(
        JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
      #expect(payload["mode"] as? String == (fieldValue.isEmpty ? nil : fieldValue))
    }
  }

  @Test func adapterRequiresEveryOwnerAndRejectsEmptyPrivateSession() throws {
    let adapter = try #require(
      ShaarNavigationAdapter(implementation: .shaar, transport: FakeNavigationEngine()))
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: ""), windowID: "w", tabID: "t",
        completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: "p", sessionID: ""), windowID: "w",
        tabID: "t", completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: "p"), windowID: "", tabID: "t",
        completion: { _ in })
    }
  }

  @Test func snapshotRejectsUnknownFieldsRedactsCredentialsAndDropsStaleGeneration() throws {
    let raw = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":"https://user:secret@example.test/path","title":"Page","loading":false,"canGoBack":true,"canGoForward":false,"sameDocument":false}"#
        .utf8)
    let snapshot = try ShaarNavigationSnapshot.decode(raw)
    #expect(snapshot.url == "https://example.test/path")

    var generations = ShaarNavigationGeneration()
    let firstAccepted = generations.accept(snapshot)
    let duplicateAccepted = generations.accept(snapshot)
    #expect(firstAccepted)
    #expect(!duplicateAccepted)
    generations.close()
    let afterCloseAccepted = generations.accept(snapshot)
    #expect(!afterCloseAccepted)

    let unknown = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"state","navigationID":"nav-2","generation":5,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"secret":"x"}"#
        .utf8)
    #expect(throws: ShaarEngineError.self) { try ShaarNavigationSnapshot.decode(unknown) }
  }

  @Test func shippingChoiceRemainsOnArdiaUntilExplicitlySelected() {
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(ShaarNavigationAdapter(transport: FakeNavigationEngine()) == nil)
  }
}
