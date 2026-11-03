// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@MainActor private final class FakeFindEngine: ShaarFindTransport, ArdiaFindBackend {
  private(set) var requests: [ShaarFindRequest] = []
  private(set) var ariaCalls: [String] = []

  func submit(
    _ request: ShaarFindRequest,
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  ) {
    requests.append(request)
    completion(.success(Data("{\"schemaVersion\":1}".utf8)))
  }

  func find(
    query: String, forward: Bool,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    ariaCalls.append("find:\(query):\(forward)")
    completion(.success(()))
  }

  func stop(
    clearSelection: Bool,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    ariaCalls.append("stop:\(clearSelection)")
    completion(.success(()))
  }
}

@Suite("Shaar find adapter")
@MainActor struct FindTests {
  @Test func defaultRemainsArdiaAndShaarBuildsVersionedFindAndStopRequests() throws {
    let fake = FakeFindEngine()
    let defaultAdapter = ShaarFindAdapter(ardia: fake, shaar: fake)
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(defaultAdapter.find(
      query: "", forward: true, scope: .init(profileID: "p"),
      windowID: "w", tabID: "t", completion: { _ in }) == nil)
    #expect(fake.ariaCalls == ["find::true"])

    let adapter = ShaarFindAdapter(implementation: .shaar, ardia: fake, shaar: fake)
    let scope = ShaarFindScope(profileID: "profile-a", sessionID: "session-a")
    let requestID = adapter.find(
      query: "needle", forward: false, scope: scope, windowID: "window-a",
      tabID: "tab-a", completion: { _ in })
    #expect(requestID == 1)
    let request = try #require(fake.requests.last)
    #expect(request.requestID == requestID)
    #expect(request.operation == .find)
    #expect(request.scope == scope)
    #expect(request.windowID == "window-a")
    #expect(request.tabID == "tab-a")
    let payload = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
    #expect(payload["query"] as? String == "needle")
    #expect(payload["forward"] as? Bool == false)

    _ = adapter.stop(
      clearSelection: false, scope: scope, windowID: "window-a", tabID: "tab-a",
      completion: { _ in })
    let stop = try #require(fake.requests.last)
    #expect(stop.operation == .stop)
    let stopPayload = try #require(
      JSONSerialization.jsonObject(with: stop.payload) as? [String: Any])
    #expect(stopPayload["selection"] as? String == "keep")
  }

  @Test func findEventsRequireExactScopeHandlesAndRequestToken() throws {
    let adapter = ShaarFindAdapter(implementation: .shaar, ardia: FakeFindEngine(),
                                   shaar: FakeFindEngine())
    let payload = Data(
      "{\"kind\":\"result\",\"schemaVersion\":1,\"requestID\":\"19\",\"matchCount\":4,\"activeMatch\":2,\"final\":true}".utf8)
    let event = ShaarCopiedEvent(
      sequence: 2, kind: 7, profileID: Data("p".utf8), sessionID: Data("s".utf8),
      windowID: Data("w".utf8), tabID: Data("t".utf8), payloadJSON: payload)
    let scope = ShaarFindScope(profileID: "p", sessionID: "s")
    let update = adapter.decode(
      event, expectedScope: scope, expectedTabID: "t", expectedRequestID: 19)
    #expect(update == ShaarFindUpdate(requestID: 19, matchCount: 4, activeMatch: 2, isFinal: true))
    #expect(adapter.decode(
      event, expectedScope: .init(profileID: "p"), expectedTabID: "t",
      expectedRequestID: 19) == nil)
    #expect(adapter.decode(
      event, expectedScope: scope, expectedTabID: "wrong", expectedRequestID: 19) == nil)
    #expect(adapter.decode(
      event, expectedScope: scope, expectedTabID: "t", expectedRequestID: 20) == nil)
  }
}
