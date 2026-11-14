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
  let payload = Data(
    #"{"schemaVersion":1,"downloads":[{"id":"guid-1","url":"https://example.test/a","filename":"a.bin","path":"/tmp/Downloads/a.bin","state":"downloading","paused":false,"received":3.0,"total":9.0,"speed":4.0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":1234.0}]}"#
      .utf8)
  let fake = FakeDownloadsTransport(replies: [400: payload])
  let result = try await ShaarDownloadsAdapter(transport: fake).list()
  #expect(result.count == 1)
  #expect(result[0].id == "guid-1")
  #expect(result[0].total == 9)
  #expect(result[0].state == .downloading)
  #expect(result[0].url == "https://example.test/a")
  #expect(result[0].filename == "a.bin")
  #expect(result[0].path == "/tmp/Downloads/a.bin")
  #expect(!result[0].paused)
  #expect(result[0].received == 3)
  #expect(result[0].speed == 4)
  #expect(result[0].mimeType == "application/octet-stream")
  #expect(!result[0].dangerous)
  #expect(!result[0].offTheRecord)
  #expect(result[0].error == nil)
  #expect(result[0].startTime == 1234)
}

@Test func downloadIdentitiesMustBeNonEmptyAndUnique() async throws {
  let duplicate = Data(
    #"{"schemaVersion":1,"downloads":[{"id":"same","url":"https://example.test/a","filename":"a","path":"/tmp/a","state":"finished","paused":false,"received":1,"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":0},{"id":"same","url":"https://example.test/b","filename":"b","path":"/tmp/b","state":"finished","paused":false,"received":1,"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":0}]}"#.utf8)
  let duplicateReply = FakeDownloadsTransport(replies: [400: duplicate])
  await #expect(throws: ShaarDownloadsError.malformedResponse) {
    _ = try await ShaarDownloadsAdapter(transport: duplicateReply).list()
  }

  let empty = Data(
    #"{"schemaVersion":1,"downloads":[{"id":"","url":"https://example.test/a","filename":"a","path":"/tmp/a","state":"finished","paused":false,"received":1,"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":0}]}"#.utf8)
  let emptyReply = FakeDownloadsTransport(replies: [400: empty])
  await #expect(throws: (any Error).self) {
    _ = try await ShaarDownloadsAdapter(transport: emptyReply).list()
  }
}

@Test func downloadRecordRequiresPrivacyBit() async throws {
  let missing = Data(
    #"{"schemaVersion":1,"downloads":[{"id":"guid-1","url":"https://example.test/a","filename":"a.bin","path":"/tmp/a.bin","state":"finished","paused":false,"received":1,"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"error":null,"startTime":0}]}"#
      .utf8)
  let fake = FakeDownloadsTransport(replies: [400: missing])
  await #expect(throws: (any Error).self) {
    _ = try await ShaarDownloadsAdapter(transport: fake).list()
  }
}

@Test func listPreservesUnknownSizeAndFailureDiagnostics() async throws {
  let payload = Data(
    #"{"schemaVersion":1,"downloads":[{"id":"guid-2","url":"https://example.test/b","filename":"b.bin","path":"","state":"failed","paused":false,"received":0,"total":-1,"speed":0,"mimeType":"application/octet-stream","dangerous":true,"offTheRecord":false,"error":"NETWORK_FAILED","startTime":0}]}"#
      .utf8)
  let fake = FakeDownloadsTransport(replies: [400: payload])
  let result = try await ShaarDownloadsAdapter(transport: fake).list()
  #expect(result[0].total == -1)
  #expect(result[0].path.isEmpty)
  #expect(result[0].dangerous)
  #expect(result[0].error == "NETWORK_FAILED")
  #expect(result[0].state == .failed)
}

@Test func downloadProgressFieldsRejectNegativeValues() async throws {
  let base =
    #"{"schemaVersion":1,"downloads":[{"id":"guid-1","url":"https://example.test/a","filename":"a.bin","path":"/tmp/a.bin","state":"downloading","paused":false,"received":0,"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":0}]}"#
  let invalid = [
    base.replacingOccurrences(of: #""received":0"#, with: #""received":-1"#),
    base.replacingOccurrences(of: #""speed":0"#, with: #""speed":-1"#),
    base.replacingOccurrences(of: #""startTime":0"#, with: #""startTime":-1"#),
  ]
  for payload in invalid {
    let fake = FakeDownloadsTransport(replies: [400: Data(payload.utf8)])
    await #expect(throws: (any Error).self) {
      _ = try await ShaarDownloadsAdapter(transport: fake).list()
    }
  }

  let unknownSize = base.replacingOccurrences(of: #""total":1"#, with: #""total":-1"#)
  let fake = FakeDownloadsTransport(replies: [400: Data(unknownSize.utf8)])
  #expect(try await ShaarDownloadsAdapter(transport: fake).list().first?.total == -1)
}

@Test func downloadIntegerFieldsRejectFractionsAndOverflow() async throws {
  for received in ["1.5", "9223372036854775808"] {
    let payload = Data(
      """
      {"schemaVersion":1,"downloads":[{"id":"guid-1","url":"https://example.test/a","filename":"a.bin","path":"/tmp/a.bin","state":"downloading","paused":false,"received":\(received),"total":1,"speed":0,"mimeType":"application/octet-stream","dangerous":false,"offTheRecord":false,"error":null,"startTime":0}]}
      """.utf8)
    let fake = FakeDownloadsTransport(replies: [400: payload])
    await #expect(throws: (any Error).self) {
      _ = try await ShaarDownloadsAdapter(transport: fake).list()
    }
  }
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

@Test func downloadControlRejectsEmptyIDBeforeSubmitting() async throws {
  let fake = FakeDownloadsTransport(replies: [401: Data("{}".utf8)])
  await #expect(throws: ShaarDownloadsError.invalidControl) {
    try await ShaarDownloadsAdapter(transport: fake).control(.pause, id: "")
  }
  #expect(await fake.recordedCalls().isEmpty)
}

@Test func directoryUsesTheAcknowledgedEnginePath() async throws {
  let fake = FakeDownloadsTransport(replies: [
    402: Data(#"{"schemaVersion":1,"directory":"/Users/test/Downloads"}"#.utf8)
  ])
  let path = try await ShaarDownloadsAdapter(transport: fake).setDirectory("/Users/test/Downloads")
  #expect(path == "/Users/test/Downloads")
}

@Test func directoryResetUsesTheEngineDefaultAcknowledgement() async throws {
  let fake = FakeDownloadsTransport(replies: [
    402: Data(#"{"schemaVersion":1,"directory":"/Users/test/Default Downloads"}"#.utf8)
  ])
  let path = try await ShaarDownloadsAdapter(transport: fake).useDefaultDirectory()
  #expect(path == "/Users/test/Default Downloads")
  let calls = await fake.recordedCalls()
  let args = try #require(JSONSerialization.jsonObject(with: calls[0].1) as? [String: Any])
  #expect(args["action"] as? String == "useDefault")
}

@Test func malformedRepliesAndTransportErrorsAreNotTurnedIntoSuccess() async throws {
  let malformed = FakeDownloadsTransport(replies: [
    400: Data(#"{"schemaVersion":2,"downloads":[]}"#.utf8)
  ])
  await #expect(throws: (any Error).self) {
    _ = try await ShaarDownloadsAdapter(transport: malformed).list()
  }

  let transportFailure = ShaarDownloadsError.engine(.notReady, message: "not initialized")
  let fake = FakeFailingDownloadsTransport(error: transportFailure)
  await #expect(throws: ShaarDownloadsError.engine(.notReady, message: "not initialized")) {
    _ = try await ShaarDownloadsAdapter(transport: fake).list()
  }
}

@Test func sourceAdapterStaysOffUntilTheShaarImplementationIsSelected() {
  let fake = FakeDownloadsTransport(replies: [:])
  #expect(ShaarDownloadsAdapter.selected(implementation: .shaar, transport: fake) != nil)
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
  #expect(
    try adapter.decodeEvent(event, profileID: "profile", sessionID: "private") == .remove("g"))
}

@Test func revealTargetMustRemainUnderTheEffectiveFolder() throws {
  let row = ShaarDownloadRecord(
    id: "g", url: "https://example.test", filename: "a", path: "/tmp/Downloads/a",
    state: .finished, paused: false, received: 1, total: 1, speed: 0,
    mimeType: "application/octet-stream", dangerous: false, offTheRecord: false, error: nil,
    startTime: 0)
  let adapter = ShaarDownloadsAdapter(transport: FakeDownloadsTransport(replies: [:]))
  #expect(throws: ShaarDownloadsError.unsafeTarget) {
    try adapter.validatedTarget(for: row, effectiveDirectory: URL(fileURLWithPath: "/tmp/Other"))
  }
}

@Test func malformedAndForeignEventsCannotUpdateTheView() throws {
  let adapter = ShaarDownloadsAdapter(transport: FakeDownloadsTransport(replies: [:]))
  let foreignProfile = ShaarCopiedEvent(
    sequence: 2, kind: 9, profileID: Data("other".utf8), sessionID: Data(), windowID: Data(),
    tabID: Data(), payloadJSON: Data("not-json".utf8))
  #expect(try adapter.decodeEvent(foreignProfile, profileID: "profile", sessionID: nil) == nil)

  let malformed = ShaarCopiedEvent(
    sequence: 3, kind: 9, profileID: Data("profile".utf8), sessionID: Data(), windowID: Data(),
    tabID: Data(), payloadJSON: Data(#"{"schemaVersion":1,"change":"upsert","download":{}}"#.utf8))
  #expect(throws: ShaarDownloadsError.malformedResponse) {
    try adapter.decodeEvent(malformed, profileID: "profile", sessionID: nil)
  }
}

@Test func downloadEventsRejectBooleanSchemaVersions() throws {
  let adapter = ShaarDownloadsAdapter(transport: FakeDownloadsTransport(replies: [:]))
  let event = ShaarCopiedEvent(
    sequence: 4, kind: 9, profileID: Data("profile".utf8), sessionID: Data(),
    windowID: Data(), tabID: Data(),
    payloadJSON: Data(#"{"schemaVersion":true,"change":"remove","downloadId":"g"}"#.utf8))
  #expect(throws: ShaarDownloadsError.malformedResponse) {
    try adapter.decodeEvent(event, profileID: "profile", sessionID: nil)
  }
}

private struct FakeFailingDownloadsTransport: ShaarDownloadsTransport {
  let error: ShaarDownloadsError

  func submit(operation: UInt32, arguments: Data) async throws -> Data {
    throw error
  }
}
