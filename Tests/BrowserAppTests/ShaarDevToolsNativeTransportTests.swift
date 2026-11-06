// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@MainActor private final class PanelRequesterFixture: ShaarPanelRequesting {
  var operations: [ShaarDevToolsOperation] = []
  var failOpen = false

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    operations.append(operation)
    if failOpen && operation == .panelOpen { throw CancellationError() }
    if operation == .panelOpen { return ["schemaVersion": 1, "leaseID": 7] }
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

  @Test func unavailablePanelKeepsStreamGated() async {
    let requester = PanelRequesterFixture()
    requester.failOpen = true
    let transport = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var iterator = transport.messages(for: target).makeAsyncIterator()
    #expect(await iterator.next() == .streamUnavailable)
  }

  private func event(_ id: Int, data: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "panelEvent", "leaseID": 7,
      "eventID": id, "data": data,
    ])
  }
}
