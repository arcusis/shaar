// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private final class FakeDevToolsEngine: ShaarDevToolsSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ShaarDevToolsRequest?
  private var reply = Data("{\"schemaVersion\":1}".utf8)
  var request: ShaarDevToolsRequest? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func setReply(_ value: String) {
    lock.lock()
    reply = Data(value.utf8)
    lock.unlock()
  }
  func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    lock.lock()
    stored = request
    let response = reply
    lock.unlock()
    Task { completion(.success(response)) }
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

  @Test func panelOpenRejectsBooleanLeaseEnvelopeFields() async throws {
    for reply in [
      #"{"schemaVersion":true,"leaseID":42}"#,
      #"{"schemaVersion":1,"leaseID":true}"#,
    ] {
      let fake = FakeDevToolsEngine(reply: Data(reply.utf8))
      let adapter = try #require(ShaarDevToolsAdapter(engine: fake))
      let result = await withCheckedContinuation { continuation in
        do {
          _ = try adapter.openPanel(
            scope: ShaarNavigationScope(profileID: "profile-a"),
            windowID: "window-a", tabID: "tab-a") {
              continuation.resume(returning: $0)
            }
        } catch {
          continuation.resume(returning: .failure(error as? ShaarEngineError ?? .invalidEvent("unexpected")))
        }
      }
      #expect(result == .failure(.invalidEvent("invalid panel lease reply")))
    }
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

  @Test func safeAreaCommandUsesScopedDeveloperCapability() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.call(
      capability: .developer, command: .emulationSetSafeAreaInsetsOverride,
      parametersJSON: Data(#"{"insets":{"top":59,"bottom":34}}"#.utf8),
      scope: ShaarNavigationScope(profileID: "profile-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })
    let request = try #require(fake.request)
    let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(root["command"] as? UInt32 == 44)
    #expect(root["capability"] as? UInt32 == ShaarDevToolsCapability.developer.rawValue)
    #expect((root["params"] as? [String: [String: Int]])?["insets"]?["top"] == 59)
    #expect(throws: ShaarEngineError.self) {
      try adapter.call(
        capability: .inspector, command: .emulationSetSafeAreaInsetsOverride,
        scope: ShaarNavigationScope(profileID: "profile-a"),
        windowID: "window-a", tabID: "tab-a", completion: { _ in })
    }
  }

  @Test func cacheDisabledCommandIsDeveloperOnly() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.call(
      capability: .developer, command: .networkSetCacheDisabled,
      parametersJSON: Data(#"{"cacheDisabled":true}"#.utf8),
      scope: ShaarNavigationScope(profileID: "profile-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })
    let request = try #require(fake.request)
    let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(root["command"] as? UInt32 == 69)
    #expect(root["capability"] as? UInt32 == ShaarDevToolsCapability.developer.rawValue)
    #expect((root["params"] as? [String: Bool])?["cacheDisabled"] == true)
    #expect(throws: ShaarEngineError.self) {
      try adapter.call(
        capability: .inspector, command: .networkSetCacheDisabled,
        scope: ShaarNavigationScope(profileID: "profile-a"),
        windowID: "window-a", tabID: "tab-a", completion: { _ in })
    }
  }

  @Test func heapProfilerCommandsAreDeveloperOnly() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let scope = ShaarNavigationScope(profileID: "profile-a")
    let commands: [ShaarDevToolsCommand] = [
      .heapProfilerTakeHeapSnapshot,
      .heapProfilerStartTrackingHeapObjects,
      .heapProfilerStopTrackingHeapObjects,
    ]
    #expect(commands.map(\.rawValue) == [77, 78, 79])
    for command in commands {
      _ = try adapter.call(
        capability: .developer, command: command, scope: scope,
        windowID: "window-a", tabID: "tab-a", completion: { _ in })
      let request = try #require(fake.request)
      let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
      #expect(root["command"] as? UInt32 == command.rawValue)
      #expect(root["capability"] as? UInt32 == ShaarDevToolsCapability.developer.rawValue)
      #expect(throws: ShaarEngineError.self) {
        try adapter.call(
          capability: .inspector, command: command, scope: scope,
          windowID: "window-a", tabID: "tab-a", completion: { _ in })
      }
      #expect(throws: ShaarEngineError.self) {
        try adapter.call(
          capability: .devToolsPanel, command: command, scope: scope,
          windowID: "window-a", tabID: "tab-a", completion: { _ in })
      }
    }
  }

  @Test func frontendUsesOnlyShowOrCloseAndRejectsMissingOwners() throws {
    let fake = FakeDevToolsEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.setFrontend(
      open: true, scope: ShaarNavigationScope(profileID: "profile-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })
    #expect(fake.request?.operation == .show)
    _ = try adapter.frontendState(
      scope: ShaarNavigationScope(profileID: "profile-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })
    #expect(fake.request?.operation == .state)
    #expect(throws: ShaarEngineError.self) {
      try adapter.setFrontend(
        open: false, scope: ShaarNavigationScope(profileID: ""),
        windowID: "window-a", tabID: "tab-a", completion: { _ in })
    }
  }

  @Test func frontendStateEventsRequireExactScopeAndMinimalPayload() {
    let scope = ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a")
    let event = ShaarCopiedEvent(
      sequence: 18, kind: 14, profileID: Data("profile-a".utf8),
      sessionID: Data("private-a".utf8), windowID: Data("window-a".utf8),
      tabID: Data("tab-a".utf8),
      payloadJSON: Data(#"{"schemaVersion":1,"kind":"frontendState","open":true}"#.utf8))
    #expect(
      ShaarDevToolsEventRouter.decodeFrontendState(
        event, scope: scope, windowID: "window-a", tabID: "tab-a")?.open == true)
    for numericOpen in ["0", "1"] {
      let numericEvent = ShaarCopiedEvent(
        sequence: event.sequence, kind: event.kind, profileID: event.profileID,
        sessionID: event.sessionID, windowID: event.windowID, tabID: event.tabID,
        payloadJSON: Data(
          #"{"schemaVersion":1,"kind":"frontendState","open":\#(numericOpen)}"#.utf8))
      #expect(
        ShaarDevToolsEventRouter.decodeFrontendState(
          numericEvent, scope: scope, windowID: "window-a", tabID: "tab-a") == nil)
    }
    #expect(
      ShaarDevToolsEventRouter.decodeFrontendState(
        event, scope: ShaarNavigationScope(profileID: "profile-a"),
        windowID: "window-a", tabID: "tab-a") == nil)

    let withSensitiveField = ShaarCopiedEvent(
      sequence: event.sequence, kind: event.kind, profileID: event.profileID,
      sessionID: event.sessionID, windowID: event.windowID, tabID: event.tabID,
      payloadJSON: Data(
        #"{"schemaVersion":1,"kind":"frontendState","open":true,"url":"https://private.test"}"#.utf8
      ))
    #expect(
      ShaarDevToolsEventRouter.decodeFrontendState(
        withSensitiveField, scope: scope, windowID: "window-a", tabID: "tab-a") == nil)

    let booleanVersion = ShaarCopiedEvent(
      sequence: 19, kind: 14, profileID: Data("profile-a".utf8),
      sessionID: Data("private-a".utf8), windowID: Data("window-a".utf8),
      tabID: Data("tab-a".utf8),
      payloadJSON: Data(
        #"{"schemaVersion":true,"kind":"frontendState","open":true}"#.utf8))
    #expect(
      ShaarDevToolsEventRouter.decodeFrontendState(
        booleanVersion, scope: scope, windowID: "window-a", tabID: "tab-a") == nil)
  }


  @Test func shaarDefaultConstructsAdapter() {
    #expect(ShaarEngineImplementation.shippingDefault == .shaar)
    #expect(ShaarDevToolsAdapter(engine: FakeDevToolsEngine()) != nil)
  }
}
