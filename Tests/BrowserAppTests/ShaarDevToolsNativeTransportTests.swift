// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@MainActor private final class PanelRequesterFixture: ShaarPanelRequesting {
  var operations: [ShaarDevToolsOperation] = []
  var payloads: [[String: Any]] = []
  var failOpen = false
  var supportsPhase2 = false

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    operations.append(operation)
    payloads.append(payload)
    if failOpen && operation == .panelOpen { throw CancellationError() }
    if operation == .panelOpen { return ["schemaVersion": 1, "leaseID": 7] }
    if operation == .panelGetResponseBody {
      return ["schemaVersion": 1, "body": "shaar-body", "base64Encoded": false]
    }
    if operation == .panelPhase2Command {
      if !supportsPhase2 { throw CancellationError() }
      return [
        "schemaVersion": 1, "commandID": payload["commandID"] as? Int ?? 0,
        "items": [], "truncated": false,
      ]
    }
    return ["schemaVersion": 1]
  }
}

@Suite @MainActor struct ShaarDevToolsNativeTransportTests {
  private let target = SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)

  @Test func scopedPanelEventReachesShellStream() async throws {
    let requester = PanelRequesterFixture()
    let windowID = UUID().uuidString
    let transport = ShaarDevToolsNativeTransport(requester: requester, windowID: windowID)
    let stream = transport.messages(for: target)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .streamAvailable)
    #expect(requester.operations.contains(.panelOpen))
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(1, data: ["text": "ready", "level": "info", "truncated": false]),
      sequence: 1)
    guard case .event(.console(let console)) = await iterator.next() else {
      Issue.record("Missing scoped console event")
      return
    }
    #expect(console.message == "ready")
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(
        29,
        data: [
          "jpegBase64": Data([0xff, 0xd8, 0xff, 0xd9]).base64EncodedString(),
          "sessionID": 3, "masked": true, "truncated": false,
        ]), sequence: 2)
    #expect(await iterator.next() == .maskedFrame(Data([0xff, 0xd8, 0xff, 0xd9])))
    for _ in 0..<20 where requester.operations.filter({ $0 == .panelScreencast }).count < 2 {
      await Task.yield()
    }
    #expect(requester.operations.filter({ $0 == .panelScreencast }).count >= 2)
  }

  @Test func responseBodyUsesTheOpenPanelLease() async throws {
    let requester = PanelRequesterFixture()
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var iterator = transport.messages(for: target).makeAsyncIterator()
    #expect(await iterator.next() == .streamAvailable)
    let stored = try await transport.responseBody(requestID: "req-9", for: target)
    #expect(stored.body == "shaar-body")
    #expect(!stored.base64Encoded)
    let payload = try #require(requester.payloads.last { $0["requestID"] as? String == "req-9" })
    #expect(payload["leaseID"] as? UInt32 == 7)
    #expect(requester.operations.contains(.panelGetResponseBody))
  }

  @Test func consoleMessageKeepsStackFramesForSources() async throws {
    let requester = PanelRequesterFixture()
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    let stream = transport.messages(for: target)
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    let text = """
      Error: shaar-source-jump
          at shaarThrowForSources (http://127.0.0.1:9/inspector-tools:8:40)
      """
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(1, data: ["text": text, "level": "error", "truncated": false]),
      sequence: 1)
    guard case .event(.console(let console)) = await iterator.next() else {
      Issue.record("Missing console stack")
      return
    }
    #expect(console.stack.count == 1)
    #expect(console.stack[0].function == "shaarThrowForSources")
    #expect(console.source?.contains("inspector-tools:8:40") == true)
  }

  @Test func unavailablePanelKeepsStreamGated() async {
    let requester = PanelRequesterFixture()
    requester.failOpen = true
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var iterator = transport.messages(for: target).makeAsyncIterator()
    #expect(await iterator.next() == .streamUnavailable)
  }

  @Test func phase2BecomesAvailableOnlyAfterNativeCommandSucceeds() async throws {
    let requester = PanelRequesterFixture()
    requester.supportsPhase2 = true
    let panel = ShaarDevToolsNativeTransport(requester: requester, windowID: UUID().uuidString)
    var panelIterator = panel.messages(for: target).makeAsyncIterator()
    #expect(await panelIterator.next() == .streamAvailable)
    let phase2 = ShaarPhase2NativeTransport(panel: panel)
    var phase2Iterator = phase2.messages(for: target).makeAsyncIterator()
    guard case .available? = await phase2Iterator.next() else {
      Issue.record("Phase 2 command probe did not enable the panel")
      return
    }
    let reply = try await phase2.execute(.resourceTree, for: target)
    #expect(reply.commandID == 15)
    #expect(requester.operations.filter({ $0 == .panelPhase2Command }).count == 2)
  }

  @Test func phase2StaysUnavailableWhenNativeOperationIsRejected() async {
    let requester = PanelRequesterFixture()
    let panel = ShaarDevToolsNativeTransport(requester: requester, windowID: UUID().uuidString)
    var panelIterator = panel.messages(for: target).makeAsyncIterator()
    #expect(await panelIterator.next() == .streamAvailable)
    var phase2Iterator = ShaarPhase2NativeTransport(panel: panel)
      .messages(for: target).makeAsyncIterator()
    guard case .unavailable? = await phase2Iterator.next() else {
      Issue.record("Unsupported phase 2 was shown as live")
      return
    }
    #expect(panel.phase2Failure != nil)
  }

  @Test func phase2EventsReachTheSharedLeaseStream() async throws {
    let requester = PanelRequesterFixture()
    requester.supportsPhase2 = true
    let panel = ShaarDevToolsNativeTransport(requester: requester, windowID: UUID().uuidString)
    var panelIterator = panel.messages(for: target).makeAsyncIterator()
    #expect(await panelIterator.next() == .streamAvailable)
    var phase2Iterator = ShaarPhase2NativeTransport(panel: panel)
      .messages(for: target).makeAsyncIterator()
    guard case .available? = await phase2Iterator.next() else {
      Issue.record("Phase 2 was unavailable")
      return
    }
    panel.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(
        12,
        data: [
          "isLocalStorage": true, "key": "theme", "value": "dark", "truncated": false,
        ]), sequence: 1)
    guard case .event(let event)? = await phase2Iterator.next() else {
      Issue.record("Missing scoped phase 2 event")
      return
    }
    #expect(event.id == .storageAdded)
    #expect(event.text["key"] == "theme")
  }

  @Test func domEventsShareLeaseWithoutInterruptingConsole() async throws {
    let requester = PanelRequesterFixture()
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var dom = transport.domSignals(for: target).makeAsyncIterator()
    var shell = transport.messages(for: target).makeAsyncIterator()
    #expect(await shell.next() == .streamAvailable)
    guard case .lease(7) = await dom.next() else {
      Issue.record("DOM observer did not receive the shared lease")
      return
    }
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(20, data: ["truncated": false]), sequence: 1)
    guard case .event(let mutationEvent) = await dom.next(),
      mutationEvent.mutation == .documentUpdated
    else {
      Issue.record("DOM observer did not receive a scoped mutation")
      return
    }
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(1, data: ["text": "still live", "level": "info", "truncated": false]),
      sequence: 2)
    guard case .event(.console(let console)) = await shell.next() else {
      Issue.record("DOM observation interrupted Console")
      return
    }
    #expect(console.message == "still live")
    #expect(console.stack.isEmpty)
    #expect(!requester.operations.contains(.panelClose))
  }

  @Test func consoleStackMapsOntoTheRow() async throws {
    let requester = PanelRequesterFixture()
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var shell = transport.messages(for: target).makeAsyncIterator()
    #expect(await shell.next() == .streamAvailable)
    transport.receive(
      tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      payload: try event(
        1,
        data: [
          "text": "boom", "level": "error", "truncated": false,
          "stack": [["function": "loadOrders", "source": "orders.ts:17"]],
        ]), sequence: 1)
    guard case .event(.console(let console)) = await shell.next() else {
      Issue.record("Console stack did not reach the shell stream")
      return
    }
    #expect(console.message == "boom")
    #expect(console.level == .error)
    #expect(console.source == "orders.ts:17")
    #expect(console.stack == [ShaarConsoleFrame(function: "loadOrders", source: "orders.ts:17")])
  }

  private func event(_ id: Int, data: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "panelEvent", "leaseID": 7,
      "eventID": id, "data": data,
    ])
  }
}
