// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private final class FakeDevToolsEngine: ShaarDevToolsSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ShaarDevToolsRequest?
  var request: ShaarDevToolsRequest? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    lock.lock()
    stored = request
    lock.unlock()
    Task { completion(.success(Data("{\"schemaVersion\":1}".utf8))) }
    return 91
  }
}

@Suite("Shaar DevTools adapter")
struct DevToolsTests {
  @Test func fixedCommandIsSubmittedWithScopeAndVersionedSchema() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let requestID = try adapter.call(
      capability: .inspector, command: .domGetDocument,
      parametersJSON: Data(#"{"depth":2}"#.utf8),
      scope: ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })

    #expect(requestID == 91)
    let request = try #require(fake.request)
    #expect(request.operation == .call)
    #expect(request.scope.sessionID == "private-a")
    #expect(request.windowID == "window-a")
    #expect(request.tabID == "tab-a")
    let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(root["schemaVersion"] as? Int == 1)
    #expect(root["capability"] as? UInt32 == ShaarDevToolsCapability.inspector.rawValue)
    #expect(root["command"] as? UInt32 == ShaarDevToolsCommand.domGetDocument.rawValue)
    #expect((root["params"] as? [String: Int])?["depth"] == 2)
  }

  @Test func commandCapabilitiesAndCookieCommandsFailClosed() throws {
    let adapter = try #require(
      ShaarDevToolsAdapter(implementation: .shaar, engine: FakeDevToolsEngine()))
    #expect(throws: ShaarEngineError.self) {
      try adapter.call(
        capability: .developer, command: .domGetDocument,
        scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
        completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.call(
        capability: .inspector, command: .networkGetCookies,
        scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
        completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.call(
        capability: .developer, command: .runtimeEvaluate,
        parametersJSON: Data("[]".utf8),
        scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
        completion: { _ in })
    }
  }

  @Test func frontendUsesOnlyShowOrCloseAndRejectsMissingOwners() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.setFrontend(
      open: true, scope: ShaarNavigationScope(profileID: "profile-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })
    #expect(fake.request?.operation == .show)
    #expect(throws: ShaarEngineError.self) {
      try adapter.setFrontend(
        open: false, scope: ShaarNavigationScope(profileID: ""),
        windowID: "window-a", tabID: "tab-a", completion: { _ in })
    }
  }

  @Test func ardiaRemainsDefaultAndDoesNotConstructShaarAdapter() {
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(ShaarDevToolsAdapter(engine: FakeDevToolsEngine()) == nil)
  }
}
