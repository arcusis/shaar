// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ShaarEngineABI

private actor FakeDownloadsTransport: ShaarDownloadsTransport {
  var replies: [UInt32: Data]
  var calls: [(UInt32, Data)] = []

  init(replies: [UInt32: Data]) { self.replies = replies }

  func submit(operation: UInt32, arguments: Data) async throws -> Data {
    calls.append((operation, arguments))
    guard let reply = replies[operation] else { throw ShaarDownloadsError.malformedResponse }
    return reply
  }

  func recordedCalls() -> [(UInt32, Data)] { calls }
}

@Test func listDecodesTheVersionedDownloadRecord() async throws {
  let payload = Data(#"{"schemaVersion":1,"downloads":[{"id":"guid-1","url":"https://example.test/a","filename":"a.bin","path":"/tmp/Downloads/a.bin","state":"downloading","paused":false,"received":3,"total":9,"speed":4,"mimeType":"application/octet-stream","dangerous":false,"error":null,"startTime":1234}]}"#.utf8)
  let fake = FakeDownloadsTransport(replies: [400: payload])
  let result = try await ShaarDownloadsAdapter(transport: fake).list()
  #expect(result.count == 1)
  #expect(result[0].id == "guid-1")
  #expect(result[0].total == 9)
  #expect(result[0].state == .downloading)
}

@Test func controlSendsTheScopedOperationSchema() async throws {
  let fake = FakeDownloadsTransport(replies: [401: Data("{}".utf8)])
  try await ShaarDownloadsAdapter(transport: fake).control(.pause, id: "guid-2")
  let calls = await fake.recordedCalls()
  #expect(calls[0].0 == 401)
  let args = try #require(JSONSerialization.jsonObject(with: calls[0].1) as? [String: Any])
  #expect(args["action"] as? String == "pause")
  #expect(args["downloadId"] as? String == "guid-2")
  #expect(args["schemaVersion"] as? Int == 1)
}

@Test func directoryUsesTheAcknowledgedEnginePath() async throws {
  let fake = FakeDownloadsTransport(replies: [402: Data(#"{"schemaVersion":1,"directory":"/Users/test/Downloads"}"#.utf8)])
  let path = try await ShaarDownloadsAdapter(transport: fake).setDirectory("/Users/test/Downloads")
  #expect(path == "/Users/test/Downloads")
}

@Test func sourceAdapterStaysOffUntilTheShaarImplementationIsSelected() {
  let fake = FakeDownloadsTransport(replies: [:])
  #expect(ShaarDownloadsAdapter.selected(implementation: .ardia, transport: fake) == nil)
  #expect(ShaarDownloadsAdapter.selected(implementation: .shaar, transport: fake) != nil)
}

@Test func privateEventsAreRejectedByTheRegularProfileView() throws {
  let fake = FakeDownloadsTransport(replies: [:])
  let adapter = ShaarDownloadsAdapter(transport: fake)
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 9, profileID: Data("profile".utf8), sessionID: Data("private".utf8),
    windowID: Data(), tabID: Data(),
    payloadJSON: Data(#"{"schemaVersion":1,"change":"remove","downloadId":"g"}"#.utf8))
  #expect(try adapter.decodeEvent(event, profileID: "profile", sessionID: nil) == nil)
  #expect(try adapter.decodeEvent(event, profileID: "profile", sessionID: "private") == .remove("g"))
}

@Test func revealTargetMustRemainUnderTheEffectiveFolder() throws {
  let row = ShaarDownloadRecord(
    id: "g", url: "https://example.test", filename: "a", path: "/tmp/Downloads/a",
    state: .finished, paused: false, received: 1, total: 1, speed: 0,
    mimeType: "application/octet-stream", dangerous: false, error: nil, startTime: 0)
  let adapter = ShaarDownloadsAdapter(transport: FakeDownloadsTransport(replies: [:]))
  #expect(throws: ShaarDownloadsError.unsafeTarget) {
    try adapter.validatedTarget(for: row, effectiveDirectory: URL(fileURLWithPath: "/tmp/Other"))
  }
}
