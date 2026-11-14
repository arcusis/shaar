// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private final class FakePanelEngine: ShaarDevToolsSubmitting, @unchecked Sendable {
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
    let reply: String
    switch request.operation {
    case .panelOpen: reply = #"{"schemaVersion":1,"leaseID":42}"#
    case .panelGetResponseBody:
      reply = #"{"schemaVersion":1,"body":"ok","base64Encoded":false}"#
    case .panelPhase2Command:
      reply =
        #"{"schemaVersion":1,"commandID":1,"items":[{"key":"a","value":"b"}],"hasMore":false,"truncated":false}"#
    default: reply = #"{"schemaVersion":1}"#
    }
    Task { completion(.success(Data(reply.utf8))) }
    return 99
  }
}

private struct BooleanSchemaNetworkRulesReplyEngine: ShaarDevToolsSubmitting {
  func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    completion(.success(Data(#"{"schemaVersion":true}"#.utf8)))
    return 1
  }
}

@Suite("Shaar DevTools panel")
struct DevToolsPanelTests {
  private let regular = ShaarNavigationScope(profileID: "profile-a")
  private let privateScope = ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a")

  private func event(
    _ payload: String, scope: ShaarNavigationScope, sequence: UInt64 = 10
  ) -> ShaarCopiedEvent {
    ShaarCopiedEvent(
      sequence: sequence, kind: 14, profileID: Data(scope.profileID.utf8),
      sessionID: Data((scope.sessionID ?? "").utf8),
      windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      payloadJSON: Data(payload.utf8))
  }

  @Test func responseBodyRequiresJSONBooleanEncodingFlag() {
    for value in ["0", "1"] {
      let payload =
        #"{"schemaVersion":1,"body":"data","base64Encoded":\#(value)}"#
      #expect(ShaarDevToolsResponseBody.decode(Data(payload.utf8)) == nil)
    }
  }

  @Test func exactScopeLeaseAndSequenceAreRequired() {
    let payload =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":4,"leaseID":42,"data":{"requestID":"r1","url":"https://example.test","method":"GET","truncated":false}}"#
    let privateEvent = event(payload, scope: privateScope)
    let decoded = ShaarDevToolsPanelEventRouter.decode(
      privateEvent, scope: privateScope, windowID: "window-a", tabID: "tab-a", leaseID: 42)
    #expect(decoded?.id == .requestWillBeSent)
    #expect(decoded?.data.url == "https://example.test")
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        privateEvent, scope: regular, windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        privateEvent, scope: privateScope, windowID: "window-b", tabID: "tab-a", leaseID: 42) == nil
    )
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        privateEvent, scope: privateScope, windowID: "window-a", tabID: "tab-a", leaseID: 41) == nil
    )
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        privateEvent, scope: privateScope, windowID: "window-a", tabID: "tab-a",
        leaseID: 42, afterSequence: 10) == nil)
  }

  @Test func panelNumericFieldsRejectBooleansAndFractions() {
    let dropped =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":11,"leaseID":42,"data":{"count":2}}"#
    let rootValues = ["schemaVersion": 1, "eventID": 11, "leaseID": 42]
    for (field, value) in rootValues {
      for replacement in ["true", "\(value).5"] {
        let payload = dropped.replacingOccurrences(
          of: "\"\(field)\":\(value)", with: "\"\(field)\":\(replacement)")
        #expect(decodePanel(payload) == nil)
      }
    }
    for replacement in ["true", "2.5"] {
      let payload = dropped.replacingOccurrences(
        of: #""count":2"#, with: "\"count\":\(replacement)")
      #expect(decodePanel(payload) == nil)
    }
    let response =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":5,"leaseID":42,"data":{"requestID":"r1","status":200,"truncated":false}}"#
    #expect(decodePanel(response) != nil)
    #expect(
      decodePanel(response.replacingOccurrences(of: #""truncated":false"#,
        with: #""truncated":0"#)) == nil)
    #expect(
      decodePanel(response.replacingOccurrences(of: #""status":200"#, with: #""status":true"#))
        == nil)
  }

  @Test func panelEventEnvelopeRejectsBooleanIntegerFields() {
    let valid =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"hello","level":"log","truncated":false}}"#
    let invalidSchema = valid.replacingOccurrences(
      of: #""schemaVersion":1"#, with: #""schemaVersion":true"#)
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        event(invalidSchema, scope: regular), scope: regular,
        windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
    let booleanLease = valid.replacingOccurrences(
      of: #""leaseID":42"#, with: #""leaseID":true"#)
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        event(booleanLease, scope: regular), scope: regular,
        windowID: "window-a", tabID: "tab-a", leaseID: 1) == nil)  }

  @Test func networkHeadersAreAcceptedOnRequestAndResponseEvents() {
    let request =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":4,"leaseID":42,"data":{"requestID":"r1","url":"https://example.test/","method":"GET","requestHeaders":[{"name":"Accept","value":"text/html"}],"truncated":false}}"#
    let response =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":5,"leaseID":42,"data":{"requestID":"r1","status":200,"responseHeaders":[{"name":"Content-Type","value":"text/html"}],"truncated":false}}"#
    #expect(decodePanel(request) != nil)
    #expect(decodePanel(response) != nil)
    let oversized = request.replacingOccurrences(
      of: "text/html", with: String(repeating: "x", count: 1_025))
    #expect(decodePanel(oversized) == nil)
    let unexpected = request.replacingOccurrences(
      of: #""value":"text/html""#,
      with: #""value":"text/html","raw":"unbounded""#)
    #expect(decodePanel(unexpected) == nil)
  }

  @Test func fixedAllowlistAndBoundsRejectUntrustedPayloads() {
    let safe =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"hello","level":"log","truncated":false}}"#
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        event(safe, scope: regular), scope: regular, windowID: "window-a",
        tabID: "tab-a", leaseID: 42)?.data.text == "hello")
    for payload in [
      safe.replacingOccurrences(of: #""eventID":1"#, with: #""eventID":99"#),
      safe.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":0"#),
      safe.replacingOccurrences(of: #""text":"hello""#, with: #""headers":{"Cookie":"secret"}"#),
      safe.replacingOccurrences(
        of: #""text":"hello""#, with: #""text":"\#(String(repeating: "x", count: 4_097))""#),
      safe.replacingOccurrences(of: #""leaseID":42"#, with: #""leaseID":43"#),
    ] {
      #expect(
        ShaarDevToolsPanelEventRouter.decode(
          event(payload, scope: regular), scope: regular, windowID: "window-a",
          tabID: "tab-a", leaseID: 42) == nil)
    }
    let dropped =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":11,"leaseID":42,"data":{"count":3}}"#
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        event(dropped, scope: regular), scope: regular, windowID: "window-a",
        tabID: "tab-a", leaseID: 42)?.data.droppedCount == 3)
  }

  @Test func consoleStackIsOptionalAndBounded() {
    let framed =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"boom","level":"error","truncated":false,"stack":[{"function":"loadOrders","source":"orders.ts:17"}]}}"#
    let decoded = decodePanel(framed)
    #expect(decoded?.data.text == "boom")
    #expect(
      decoded?.data.stack == [
        ShaarDevToolsConsoleFrame(function: "loadOrders", source: "orders.ts:17")
      ])
    let plain =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"hello","level":"log","truncated":false}}"#
    #expect(decodePanel(plain)?.data.stack.isEmpty == true)
    let thrown =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":2,"leaseID":42,"data":{"text":"Error","truncated":true,"stack":[{"function":"raise","source":"app.js:1"}]}}"#
    #expect(decodePanel(thrown)?.data.stack.first?.function == "raise")
    #expect(decodePanel(thrown)?.data.stack.first?.source == "app.js:1")
    let extraKey =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"boom","level":"error","truncated":false,"stack":[{"function":"loadOrders","source":"orders.ts:17","scriptId":"secret"}]}}"#
    #expect(decodePanel(extraKey) == nil)
    let oversized = String(repeating: "f", count: 129)
    let tooLong =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"boom","level":"error","truncated":false,"stack":[{"function":"\#(oversized)","source":"app.js:1"}]}}"#
    #expect(decodePanel(tooLong) == nil)
    let frames = (0..<9).map { _ in #"{"function":"frame","source":"app.js:1"}"# }
      .joined(separator: ",")
    let tooMany =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":1,"leaseID":42,"data":{"text":"many","level":"log","truncated":true,"stack":[\#(frames)]}}"#
    #expect(decodePanel(tooMany) == nil)
  }

  private func decodePanel(_ payload: String) -> ShaarDevToolsPanelEvent? {
    ShaarDevToolsPanelEventRouter.decode(
      event(payload, scope: regular), scope: regular, windowID: "window-a",
      tabID: "tab-a", leaseID: 42)
  }

  @Test func webSocketEventsKeepOnlyBoundedFrameFields() {
    let created =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":31,"leaseID":42,"data":{"requestID":"ws-1","url":"ws://example.test/ws","truncated":false}}"#
    let handshake =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":32,"leaseID":42,"data":{"requestID":"ws-1","status":101,"truncated":false}}"#
    let frame =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":34,"leaseID":42,"data":{"requestID":"ws-1","opcode":1,"payload":"echo-ready","truncated":false}}"#
    #expect(decodePanel(created)?.data.url == "ws://example.test/ws")
    #expect(decodePanel(handshake)?.data.status == 101)
    #expect(decodePanel(frame)?.data.payload == "echo-ready")
    #expect(decodePanel(frame)?.data.opcode == 1)
    #expect(
      decodePanel(frame.replacingOccurrences(of: #""opcode":1"#, with: #""opcode":16"#)) == nil)
    #expect(
      decodePanel(
        frame.replacingOccurrences(
          of: #""payload":"echo-ready""#,
          with: #""payload":"\#(String(repeating: "x", count: 4_097))""#)) == nil)
    #expect(
      decodePanel(
        frame.replacingOccurrences(
          of: #""payload":"echo-ready""#,
          with: #""headers":{"Cookie":"secret"}"#)) == nil)
  }

  @Test func screencastFramesRequireMaskAndExactTabLease() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
    let payload =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":29,"leaseID":42,"data":{"jpegBase64":"\#(jpeg)","sessionID":7,"masked":true,"truncated":false}}"#
    let safe = event(payload, scope: privateScope)
    let decoded = ShaarDevToolsPanelEventRouter.decode(
      safe, scope: privateScope, windowID: "window-a", tabID: "tab-a", leaseID: 42)
    #expect(decoded?.id == .screencastFrame)
    #expect(decoded?.data.frame?.jpeg == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    for unsafe in [
      payload.replacingOccurrences(of: #""masked":true"#, with: #""masked":false"#),
      payload.replacingOccurrences(of: #""masked":true"#, with: #""masked":1"#),
      payload.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":0"#),
      payload.replacingOccurrences(of: #""masked":true"#, with: #""masked":true,"headers":{}"#),
      payload.replacingOccurrences(of: #""sessionID":7"#, with: #""sessionID":0"#),
    ] {
      #expect(
        ShaarDevToolsPanelEventRouter.decode(
          event(unsafe, scope: privateScope), scope: privateScope,
          windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
    }
    #expect(
      ShaarDevToolsPanelEventRouter.decode(
        safe, scope: privateScope, windowID: "window-a", tabID: "another-tab", leaseID: 42) == nil)
  }

  @Test func adapterSubmitsVersionedLeaseOperations() throws {
    let fake = FakePanelEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.openPanel(scope: privateScope, windowID: "window-a", tabID: "tab-a") { _ in }
    #expect(fake.request?.operation == .panelOpen)
    #expect(fake.request?.scope.sessionID == "private-a")
    _ = try adapter.closePanel(
      leaseID: 42, scope: privateScope,
      windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    #expect(fake.request?.operation == .panelClose)
    _ = try adapter.getPanelResponseBody(
      leaseID: 42, requestID: "r1", scope: privateScope,
      windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    #expect(fake.request?.operation == .panelGetResponseBody)
    let request = try #require(fake.request)
    let object = try #require(
      JSONSerialization.jsonObject(
        with: request.payload) as? [String: Any])
    #expect(object["leaseID"] as? Int == 42)
    #expect(object["requestID"] as? String == "r1")
    #expect(throws: ShaarEngineError.self) {
      try adapter.closePanel(
        leaseID: 0, scope: regular,
        windowID: "window-a", tabID: "tab-a"
      ) { _ in }
    }
  }

  @Test func screencastCommandsUseFixedIDsAndScopedLease() throws {
    let fake = FakePanelEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    _ = try adapter.screencastCommand(
      .start, leaseID: 42, scope: privateScope,
      windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    let start = try #require(fake.request)
    #expect(start.operation == .panelScreencast)
    #expect(start.scope.sessionID == "private-a")
    let startJSON = try #require(
      JSONSerialization.jsonObject(with: start.payload) as? [String: Any])
    #expect(startJSON["commandID"] as? Int == 1)
    _ = try adapter.screencastCommand(
      .ack(sessionID: 7), leaseID: 42, scope: privateScope,
      windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    let ack = try #require(fake.request)
    let ackJSON = try #require(JSONSerialization.jsonObject(with: ack.payload) as? [String: Any])
    #expect(ackJSON["commandID"] as? Int == 3)
    #expect(ackJSON["sessionID"] as? Int == 7)
    #expect(throws: ShaarEngineError.self) {
      try adapter.screencastCommand(
        .ack(sessionID: 0), leaseID: 42, scope: regular,
        windowID: "window-a", tabID: "tab-a"
      ) { _ in }
    }
  }

  @Test func responseBodyRejectsOversizeAndExtraFields() {
    #expect(
      ShaarDevToolsResponseBody.decode(
        Data(
          #"{"schemaVersion":1,"body":"ok","base64Encoded":false}"#.utf8))?.body == "ok")
    #expect(
      ShaarDevToolsResponseBody.decode(
        Data(
          #"{"schemaVersion":1,"body":"ok","base64Encoded":false,"headers":{}}"#.utf8)) == nil)
    let huge = String(repeating: "x", count: 1_048_577)
    let payload = #"{"schemaVersion":1,"body":"\#(huge)","base64Encoded":false}"#
    #expect(ShaarDevToolsResponseBody.decode(Data(payload.utf8)) == nil)
  }

  @Test func responseBodyRejectsMalformedRequiredFields() {
    for payload in [
      #"{"schemaVersion":2,"body":"ok","base64Encoded":false}"#,
      #"{"schemaVersion":1,"body":7,"base64Encoded":false}"#,
      #"{"schemaVersion":1,"body":"ok","base64Encoded":"false"}"#,
      #"{"schemaVersion":1,"body":"ok","base64Encoded":0}"#,
      #"{"schemaVersion":1,"body":"ok","base64Encoded":1}"#,
      "not-json",
    ] {
      #expect(ShaarDevToolsResponseBody.decode(Data(payload.utf8)) == nil)
    }
  }

  @Test func networkRulesUseFixedActionsAndScopedLease() throws {
    let fake = FakePanelEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let mock = ShaarDevToolsNetworkRule(
      method: "GET", url: "https://example.test/data", kind: .mock,
      status: 201, headers: [.init(name: "Content-Type", value: "text/plain")],
      bodyBase64: Data("hello".utf8).base64EncodedString())
    _ = try adapter.setPanelNetworkRules(
      [mock], leaseID: 42, scope: privateScope, windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    let request = try #require(fake.request)
    #expect(request.operation == .panelNetworkRules)
    #expect(request.operation.rawValue == 1080)
    #expect(request.scope.sessionID == "private-a")
    let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(Set(root.keys) == ["schemaVersion", "leaseID", "rules"])
    #expect(root["leaseID"] as? Int == 42)
    let rows = try #require(root["rules"] as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0]["kind"] as? String == "mock")
    #expect(rows[0]["bodyBase64"] as? String == "aGVsbG8=")
    #expect(rows[0]["bodyFilePath"] == nil)
    #expect(throws: ShaarEngineError.self) {
      try adapter.setPanelNetworkRules(
        [mock], leaseID: 0, scope: regular, windowID: "window-a", tabID: "tab-a"
      ) { _ in }
    }
  }

  @Test func networkRulesRejectUnsafeValuesBeforeSubmit() throws {
    let fake = FakePanelEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let unsafe = ShaarDevToolsNetworkRule(
      method: "GET", url: "file:///private/data", kind: .requestHeaders,
      headers: [.init(name: "X-Test", value: "bad\r\nvalue")])
    #expect(throws: ShaarEngineError.self) {
      try adapter.setPanelNetworkRules(
        [unsafe], leaseID: 42, scope: regular, windowID: "window-a", tabID: "tab-a"
      ) { _ in }
    }
    #expect(fake.request == nil)
  }

  @Test func networkRulesRejectBooleanReplySchemaVersion() async throws {
    let adapter = try #require(
      ShaarDevToolsAdapter(implementation: .shaar, engine: BooleanSchemaNetworkRulesReplyEngine()))
    await #expect(throws: ShaarEngineError.self) {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        do {
          _ = try adapter.setPanelNetworkRules(
            [], leaseID: 42, scope: regular, windowID: "window-a", tabID: "tab-a"
          ) { result in
            continuation.resume(with: result.map { _ in () }.mapError { $0 as Error })
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  @Test func phase2FixtureUsesFixedCommandAndScopedLease() throws {
    let fake = FakePanelEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let command = ShaarDevToolsPhase2Command.storageItems(local: false, skip: 0, count: 50)
    _ = try adapter.phase2Command(
      command, leaseID: 42, scope: privateScope, windowID: "window-a", tabID: "tab-a"
    ) { _ in }
    let request = try #require(fake.request)
    #expect(request.operation == .panelPhase2Command)
    #expect(request.scope.sessionID == "private-a")
    let root = try #require(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(root["commandID"] as? Int == 1)
    #expect(root["leaseID"] as? Int == 42)
    let params = try #require(root["params"] as? [String: Any])
    #expect(params["isLocalStorage"] as? Bool == false)
    #expect(params["pageSize"] as? Int == 50)
    #expect(throws: ShaarEngineError.self) {
      try adapter.phase2Command(
        .indexedDBData(database: "db", store: "store", skip: 0, count: 51),
        leaseID: 42, scope: regular, windowID: "window-a", tabID: "tab-a"
      ) { _ in }
    }
  }

  @Test func phase2RepliesAreBoundedAndCommandMatched() {
    let command = ShaarDevToolsPhase2Command.cacheNames
    let safe =
      #"{"schemaVersion":1,"commandID":8,"items":[{"cacheID":"c1","name":"assets"}],"truncated":false}"#
    #expect(
      ShaarDevToolsPhase2Reply.decode(Data(safe.utf8), command: command)?.items.first?.text["name"]
        == "assets")
    #expect(ShaarDevToolsPhase2Reply.decode(Data(safe.utf8), command: .indexedDBNames) == nil)
    let withHeaders = safe.replacingOccurrences(
      of: #""name":"assets""#, with: #""headers":{"Cookie":"secret"}"#)
    #expect(ShaarDevToolsPhase2Reply.decode(Data(withHeaders.utf8), command: command) == nil)
    func resourceReply(bodyBytes: Int) -> Data {
      let body = String(repeating: "x", count: bodyBytes)
      let reply =
        #"{"schemaVersion":1,"commandID":16,"items":[],"body":"\#(body)","base64Encoded":false,"truncated":false}"#
      return Data(reply.utf8)
    }
    let resource = ShaarDevToolsPhase2Command.resourceContent(url: "https://example.test/a.js")
    let acceptedBodyBytes = ShaarDevToolsPhase2Reply.decode(
      resourceReply(bodyBytes: 1_048_577), command: resource)?.body?.utf8.count
    #expect(acceptedBodyBytes == 1_048_577)
    let rejectsOverLimit =
      ShaarDevToolsPhase2Reply.decode(
        resourceReply(bodyBytes: 5 * 1_048_576 + 1), command: resource) == nil
    #expect(rejectsOverLimit)
    let vitals =
      #"{"schemaVersion":1,"commandID":18,"items":[{"name":"ttfb","value":120.0},{"name":"event","startTime":300.0,"duration":80.0,"interactionID":1}],"truncated":false}"#
    #expect(
      ShaarDevToolsPhase2Reply.decode(Data(vitals.utf8), command: .vitalsInputs)?
        .items.last?.number["interactionID"] == 1)
  }

  @Test func parsedScriptCommandsAndEventsStayScoped() throws {
    let page = ShaarDevToolsPhase2Command.parsedScripts(skip: 50, count: 50)
    #expect(page.id == 19)
    #expect(page.parameters?["skipCount"] as? Int == 50)
    #expect(ShaarDevToolsPhase2Command.parsedScripts(skip: 0, count: 51).parameters == nil)
    let source = ShaarDevToolsPhase2Command.scriptSource(id: "42")
    #expect(source.id == 20)
    #expect(source.parameters?["scriptID"] as? String == "42")
    let scripts =
      #"{"schemaVersion":1,"commandID":19,"items":[{"url":"https://example.test/App.vue","scriptID":"42","sourceMapURL":"App.vue.map"}],"hasMore":false,"truncated":false}"#
    #expect(
      ShaarDevToolsPhase2Reply.decode(Data(scripts.utf8), command: page)?
        .items.first?.text["scriptID"] == "42")
    let body =
      #"{"schemaVersion":1,"commandID":20,"items":[],"body":"export const app = 1;","base64Encoded":false,"truncated":false}"#
    #expect(
      ShaarDevToolsPhase2Reply.decode(Data(body.utf8), command: source)?.body
        == "export const app = 1;")
    let payload =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":30,"leaseID":42,"data":{"url":"https://example.test/App.vue","scriptID":"42","truncated":false}}"#
    let parsed = ShaarDevToolsPhase2EventRouter.decode(
      event(payload, scope: privateScope), scope: privateScope,
      windowID: "window-a", tabID: "tab-a", leaseID: 42)
    #expect(parsed?.id == .scriptParsed)
    #expect(parsed?.text["scriptID"] == "42")
  }

  @Test func phase2EventsRejectOtherSessionAndUnknownFields() {
    let payload =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":12,"leaseID":42,"data":{"isLocalStorage":true,"key":"k","value":"v","truncated":false}}"#
    let source = event(payload, scope: privateScope)
    let decoded = ShaarDevToolsPhase2EventRouter.decode(
      source, scope: privateScope, windowID: "window-a", tabID: "tab-a", leaseID: 42)
    #expect(decoded?.id == .storageAdded)
    #expect(decoded?.text["value"] == "v")
    #expect(
      ShaarDevToolsPhase2EventRouter.decode(
        source, scope: regular, windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
    let injected = payload.replacingOccurrences(
      of: #""key":"k""#, with: #""headers":{"Cookie":"secret"}"#)
    #expect(
      ShaarDevToolsPhase2EventRouter.decode(
        event(injected, scope: privateScope), scope: privateScope,
        windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
  }

  @Test func phase2EventIntegerFieldsRejectBooleansAndFractions() {
    let valid =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":12,"leaseID":42,"data":{"isLocalStorage":true,"key":"k","value":"v","truncated":false}}"#
    for payload in [
      valid.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":true"#),
      valid.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":1.5"#),
      valid.replacingOccurrences(of: #""eventID":12"#, with: #""eventID":12.5"#),
      valid.replacingOccurrences(of: #""leaseID":42"#, with: #""leaseID":42.5"#),
    ] {
      #expect(
        ShaarDevToolsPhase2EventRouter.decode(
          event(payload, scope: privateScope), scope: privateScope,
          windowID: "window-a", tabID: "tab-a", leaseID: 42) == nil)
    }
    let booleanLease = valid.replacingOccurrences(
      of: #""leaseID":42"#, with: #""leaseID":true"#)
    #expect(
      ShaarDevToolsPhase2EventRouter.decode(
        event(booleanLease, scope: privateScope), scope: privateScope,
        windowID: "window-a", tabID: "tab-a", leaseID: 1) == nil)
  }
}
