// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeHistoryEngine: ShaarHistorySubmitting {
  struct Call: Sendable {
    let profileID: UUID
    let operation: ShaarHistoryOperation
    let argsJSON: Data
  }
  var reply: Data
  private(set) var calls: [Call] = []

  init(reply: String) { self.reply = Data(reply.utf8) }

  func submitHistory(profileID: UUID, operation: ShaarHistoryOperation, argsJSON: Data) async throws
    -> Data
  {
    calls.append(Call(profileID: profileID, operation: operation, argsJSON: argsJSON))
    return reply
  }

  func setReply(_ value: String) { reply = Data(value.utf8) }
}

@Suite("Shaar history adapter")
struct ShaarHistoryAdapterTests {
  @Test func queryDecodesStrictRowsAndUsesSelectedProfile() async throws {
    let profile = UUID()
    let fake = FakeHistoryEngine(
      reply:
        #"{"schemaVersion":1,"entries":[{"url":"https://example.test/a","title":"A","visitCount":3,"visits":[1700000000123]}]}"#
    )
    let adapter = ShaarHistoryAdapter(engine: fake)
    let entries = try await adapter.query(profileID: profile, maxUrls: 100, maxVisitsPerURL: 1)
    #expect(entries.count == 1)
    #expect(entries[0].visitCount == 3)
    #expect(entries[0].visits == [1_700_000_000_123])
    let calls = await fake.calls
    #expect(calls.first?.profileID == profile)
    #expect(calls.first?.operation == .query)
    let args = try #require(JSONSerialization.jsonObject(with: calls[0].argsJSON) as? [String: Int])
    #expect(args["maxUrls"] == 100)
  }

  @Test func queryRejectsDuplicateURLsAndUnsupportedSchemes() async throws {
    let duplicate =
      #"{"schemaVersion":1,"entries":[{"url":"https://example.test/","title":"A","visitCount":1,"visits":[1]},{"url":"https://example.test/","title":"A","visitCount":1,"visits":[2]}]}"#
    let fake = FakeHistoryEngine(reply: duplicate)
    let adapter = ShaarHistoryAdapter(engine: fake)
    await #expect(
      throws: ShaarHistoryAdapterError.invalidResponse("malformed or duplicate history row")
    ) {
      try await adapter.query(profileID: UUID())
    }
    await fake.setReply(
      #"{"schemaVersion":1,"entries":[{"url":"file:///tmp/a","title":"A","visitCount":1,"visits":[1]}]}"#
    )
    await #expect(
      throws: ShaarHistoryAdapterError.invalidResponse("malformed or duplicate history row")
    ) {
      try await adapter.query(profileID: UUID())
    }
  }

  @Test func insertDeleteWatchAreBoundToExplicitProfile() async throws {
    let profile = UUID()
    let fake = FakeHistoryEngine(
      reply:
        #"{"schemaVersion":1,"accepted":1,"insertedVisits":2,"duplicateVisits":0,"rejected":[]}"#)
    let adapter = ShaarHistoryAdapter(engine: fake)
    let imported = try await adapter.insert(
      profileID: profile, source: "firefox",
      pages: [
        .init(url: "https://import.example/", title: "Imported", visits: [1, 2])
      ])
    #expect(imported.insertedVisits == 2)
    await fake.setReply(#"{"schemaVersion":1,"deleted":1}"#)
    #expect(
      try await adapter.delete(profileID: profile, urls: [URL(string: "https://import.example/")!])
        == 1)
    await fake.setReply(#"{"schemaVersion":1,"subscriptionId":"sub-1"}"#)
    let token = try await adapter.watch(profileID: profile)
    #expect(token == "sub-1")
    await fake.setReply(#"{"schemaVersion":1}"#)
    try await adapter.unwatch(profileID: profile, subscriptionID: token)
    let calls = await fake.calls
    #expect(calls.map(\.operation) == [.insert, .delete, .watch, .unwatch])
    #expect(calls.allSatisfy { $0.profileID == profile })
  }

  @Test func insertPreservesSourceAndReportsMixedImportCounts() async throws {
    let profile = UUID()
    let fake = FakeHistoryEngine(
      reply:
        #"{"schemaVersion":1,"accepted":2,"insertedVisits":2,"duplicateVisits":3,"rejected":[{"index":2,"code":"not_addable"}]}"#
    )
    let adapter = ShaarHistoryAdapter(engine: fake)
    let pages = [
      ShaarHistoryInsertPage(
        url: "https://import.example/", title: "Imported", visits: [1_700_000_000_123]),
      ShaarHistoryInsertPage(
        url: "https://import.example/second", title: nil, visits: [1_700_000_001_456]),
      ShaarHistoryInsertPage(url: "https://rejected.example/", visits: [1_700_000_002_789]),
    ]

    for source in ["safari", "chrome", "arc", "firefox"] {
      let result = try await adapter.insert(profileID: profile, source: source, pages: pages)
      #expect(result.accepted == 2)
      #expect(result.insertedVisits == 2)
      #expect(result.duplicateVisits == 3)
      #expect(result.rejected == [.init(index: 2, code: "not_addable")])
    }

    let calls = await fake.calls
    #expect(calls.count == 4)
    for (call, expectedSource) in zip(calls, ["safari", "chrome", "arc", "firefox"]) {
      #expect(call.profileID == profile)
      #expect(call.operation == .insert)
      let request = try #require(
        JSONSerialization.jsonObject(with: call.argsJSON) as? [String: Any])
      #expect(request["schemaVersion"] as? Int == 1)
      #expect(request["source"] as? String == expectedSource)
      let submittedPages = try #require(request["pages"] as? [[String: Any]])
      #expect(submittedPages.count == pages.count)
      #expect(submittedPages[0]["visits"] as? [Int] == [1_700_000_000_123])
    }
  }

  @Test func malformedTypedResultsAreRejected() async throws {
    let fake = FakeHistoryEngine(reply: #"{"schemaVersion":1,"deleted":999}"#)
    let adapter = ShaarHistoryAdapter(engine: fake)
    await #expect(throws: ShaarHistoryAdapterError.invalidResponse("invalid delete result")) {
      try await adapter.delete(profileID: UUID(), urls: [URL(string: "https://example.test")!])
    }
  }

  @Test func queryRejectsBooleanIntegerFields() async throws {
    let row = #""url":"https://example.test/","title":"A","visitCount":1,"visits":[1]"#
    let replies = [
      #"{"schemaVersion":true,"entries":[]}"#,
      "{\"schemaVersion\":1,\"entries\":[{" + row + "]}",
      #"{"schemaVersion":1,"entries":[{"url":"https://example.test/","title":"A","visitCount":1,"visits":[true]}]}"#,
    ]
    for reply in replies {
      let fake = FakeHistoryEngine(reply: reply)
      await #expect(throws: (any Error).self) {
        try await ShaarHistoryAdapter(engine: fake).query(profileID: UUID())
      }
    }
  }

  @Test func insertRejectsNegativeVisitTimestampsBeforeSubmit() async throws {
    let fake = FakeHistoryEngine(reply: #"{"schemaVersion":1}"#)
    let adapter = ShaarHistoryAdapter(engine: fake)
    await #expect(
      throws: ShaarHistoryAdapterError.invalidResponse("invalid import batch")
    ) {
      try await adapter.insert(
        profileID: UUID(), source: "firefox",
        pages: [.init(url: "https://example.test/", visits: [-1])])
    }
    #expect(await fake.calls.isEmpty)
  }

  @Test func eventRouterRequiresKnownRegularProfileAndValidHistoryEnvelope() {
    let profile = UUID()
    let id = Data(profile.uuidString.utf8)
    let payload = Data(#"{"schemaVersion":1,"kind":"changed"}"#.utf8)
    let regular = ShaarCopiedEvent(
      sequence: 2, kind: 11, profileID: id, sessionID: Data(),
      windowID: Data(), tabID: Data(), payloadJSON: payload)
    #expect(
      ShaarHistoryEventRouter.changedProfile(for: regular, knownProfiles: [profile]) == profile)
    let booleanSchemaEvent = ShaarCopiedEvent(
      sequence: 4, kind: 11, profileID: id, sessionID: Data(),
      windowID: Data(), tabID: Data(),
      payloadJSON: Data(#"{"schemaVersion":true,"kind":"changed"}"#.utf8))
    #expect(
      ShaarHistoryEventRouter.changedProfile(
        for: booleanSchemaEvent, knownProfiles: [profile]) == nil)
    let privateEvent = ShaarCopiedEvent(
      sequence: 3, kind: 11, profileID: id,
      sessionID: Data("private-session".utf8), windowID: Data(),
      tabID: Data(), payloadJSON: payload)
    #expect(
      ShaarHistoryEventRouter.changedProfile(for: privateEvent, knownProfiles: [profile]) == nil)
    #expect(ShaarHistoryEventRouter.changedProfile(for: regular, knownProfiles: []) == nil)
    let booleanVersion = ShaarCopiedEvent(
      sequence: 4, kind: 11, profileID: id, sessionID: Data(),
      windowID: Data(), tabID: Data(),
      payloadJSON: Data(#"{"schemaVersion":true,"kind":"changed"}"#.utf8))
    #expect(
      ShaarHistoryEventRouter.changedProfile(for: booleanVersion, knownProfiles: [profile]) == nil)
  }

  @Test func historyEventSchemaVersionMustBeAnInteger() {
    let profile = UUID()
    let event = ShaarCopiedEvent(
      sequence: 1, kind: 11, profileID: Data(profile.uuidString.utf8), sessionID: Data(),
      windowID: Data(), tabID: Data(),
      payloadJSON: Data(#"{"schemaVersion":true,"kind":"changed"}"#.utf8))
    #expect(ShaarHistoryEventRouter.changedProfile(for: event, knownProfiles: [profile]) == nil)
  }
}
