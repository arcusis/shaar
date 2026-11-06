// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

private final class FakeNetworkRulesABIEngine: ShaarDevToolsSubmitting, @unchecked Sendable {
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
    completion(.success(Data(#"{"schemaVersion":1}"#.utf8)))
    return 1
  }
}

@MainActor private final class FakePanelRulesRequester: ShaarPanelRequesting {
  var requests: [(ShaarDevToolsOperation, SiteControlTarget, [String: Any])] = []

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    requests.append((operation, target, payload))
    if operation == .panelOpen { return ["leaseID": 7] }
    return ["schemaVersion": 1]
  }
}

@Suite @MainActor struct ShaarNetworkRulesTests {
  @Test func requestDraftStartsDisabledAndPreservesExactMatch() throws {
    let row = ShaarNetworkRequest(
      id: "request-1", method: "POST", url: "http://localhost:3000/api/orders",
      status: 503, mimeType: "application/json", encodedBytes: 200,
      startedAt: 0, respondedAt: nil, completedAt: nil, failure: nil,
      requestHeaders: [], responseHeaders: [], payload: nil, responseBody: "{\"error\":true}")
    let draft = ShaarNetworkRule.fromRequest(row)
    #expect(!draft.enabled)
    #expect(draft.method == "POST")
    #expect(draft.url == "http://localhost:3000/api/orders")
    #expect(draft.kind == .mock)
    #expect(draft.status == 503)
    #expect(draft.bodyText == "{\"error\":true}")
    try draft.validate()
  }

  @Test func validationRejectsUnsafeOrUnboundedInputs() throws {
    var rule = ShaarNetworkRule.fromRequest(request())
    rule.url = "file:///etc/passwd"
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
    rule.url = "https://user:pass@example.com/api"
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
    rule.url = "https://example.com/api"
    rule.headers = [.init(name: "X-Test", value: "safe\r\nInjected: yes")]
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
    rule.headers = []
    rule.kind = .delay
    rule.delayMilliseconds = 30_001
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
    rule.kind = .redirect
    rule.redirectURL = "javascript:alert(1)"
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
    rule.kind = .mock
    rule.bodyText = String(repeating: "x", count: 1_048_577)
    #expect(throws: ShaarNetworkRuleError.self) { try rule.validate() }
  }

  @Test func fileBodyIsResolvedAtApplyTimeAndBounded() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "response.json")
    try Data("{\"ok\":true}".utf8).write(to: file)
    var rule = ShaarNetworkRule.fromRequest(request())
    rule.bodyFilePath = file.path
    #expect(String(data: try rule.bodyData(), encoding: .utf8) == "{\"ok\":true}")
    try Data(repeating: 65, count: 1_048_577).write(to: file)
    #expect(throws: ShaarNetworkRuleError.self) { try rule.bodyData() }
  }

  @Test func savedRulesAreSeparatedBySiteAndStartOff() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShaarNetworkRuleStore(root: root)
    let first = "profile-a|http://localhost:3000"
    let second = "profile-a|http://localhost:4000"
    var rule = ShaarNetworkRule.fromRequest(request())
    rule.enabled = true
    try store.save([rule], for: first)
    #expect(try store.load(for: first) == [rule])
    #expect(try store.load(for: second).isEmpty)
    #expect(try store.load(for: first).first?.enabled == true)
    #expect(store.fileURL(for: first) != store.fileURL(for: second))
  }

  @Test func fixtureAppliesOnlyEnabledRulesForCurrentTab() async throws {
    let target = target()
    let transport = ShaarNetworkRulesFixtureTransport()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShaarNetworkRulesModel(
      target: target, store: ShaarNetworkRuleStore(root: root), transport: transport)
    model.create(from: request())
    #expect(model.draft?.enabled == false)
    model.draft?.enabled = true
    try await model.saveDraft()
    #expect(model.activeCount == 1)
    #expect(transport.lastTarget == target)
    #expect(transport.lastRules.count == 1)
    #expect(transport.lastRules.first?.bodyBase64 == "")
    model.updateTarget(
      SiteControlTarget(
        tabID: UUID(), profileID: target.profileID,
        url: URL(string: "http://localhost:4000")!))
    #expect(model.activeCount == 0)
    #expect(model.rules.isEmpty)
  }

  @Test func productionTransportKeepsSavedRulesInactive() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShaarNetworkRulesModel(
      target: target(), store: ShaarNetworkRuleStore(root: root))
    model.create(from: request())
    model.draft?.enabled = true
    try await model.saveDraft()
    #expect(!model.available)
    #expect(model.rules.first?.enabled == true)
    #expect(model.activeCount == 0)
  }

  @Test func mappedProjectsAtSameOriginKeepSeparateRules() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let first = temporary.appending(path: "first")
    let second = temporary.appending(path: "second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let transport = ShaarNetworkRulesFixtureTransport()
    let model = ShaarNetworkRulesModel(
      target: target(), store: ShaarNetworkRuleStore(root: temporary.appending(path: "store")),
      transport: transport)
    try await model.useProjectRoot(first.path)
    model.create(from: request())
    model.draft?.enabled = true
    try await model.saveDraft()
    let firstProject = try #require(model.project)
    #expect(model.activeCount == 1)
    try await model.useProjectRoot(second.path)
    #expect(model.rules.isEmpty)
    #expect(model.activeCount == 0)
    #expect(transport.lastRules.isEmpty)
    #expect(model.project != firstProject)
    try await model.useProjectRoot(first.path)
    #expect(model.rules.count == 1)
    #expect(model.activeCount == 1)
    #expect(model.projectLabel == "first")
    try await model.useProjectRoot(nil)
    #expect(model.projectRoot == nil)
    #expect(model.rules.isEmpty)
    #expect(transport.lastRules.isEmpty)
    try await model.useProjectRoot(first.path)
    model.updateTarget(model.target, committed: true)
    #expect(model.activeCount == 0)
    #expect(model.projectRoot == nil)
    #expect(model.rules.isEmpty)
  }

  @Test func leasedTransportSendsResolvedBodyToOwnedTab() async throws {
    let target = target()
    let fake = FakeNetworkRulesABIEngine()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: fake))
    let transport = ShaarNetworkRulesLeasedTransport(
      adapter: adapter, leaseID: 7,
      scope: ShaarNavigationScope(profileID: target.profileID.uuidString),
      windowID: UUID().uuidString, tabID: target.tabID.uuidString, target: target)
    var rule = ShaarNetworkRule.fromRequest(request())
    rule.bodyText = "fixture response"
    try await transport.apply([ShaarResolvedNetworkRule(rule)], to: target)
    let submitted = try #require(fake.request)
    #expect(submitted.operation == .panelNetworkRules)
    #expect(submitted.tabID == target.tabID.uuidString)
    let root = try #require(
      JSONSerialization.jsonObject(with: submitted.payload) as? [String: Any])
    let rows = try #require(root["rules"] as? [[String: Any]])
    #expect(
      rows.first?["bodyBase64"] as? String == Data("fixture response".utf8).base64EncodedString())
    #expect(rows.first?["bodyFilePath"] == nil)
    let other = SiteControlTarget(tabID: UUID(), profileID: target.profileID, url: target.url)
    await #expect(throws: ShaarNetworkRuleError.self) {
      try await transport.apply([], to: other)
    }
  }

  @Test func nativeRuleTransportWaitsForOwnedLeaseAndRejectsStaleTab() async throws {
    let owner = target()
    let requester = FakePanelRulesRequester()
    let panel = ShaarDevToolsNativeTransport(requester: requester, windowID: UUID().uuidString)
    let transport = ShaarNetworkRulesNativeTransport(panel: panel)
    var rule = ShaarNetworkRule.fromRequest(request())
    rule.bodyText = "fixture response"
    let resolved = try ShaarResolvedNetworkRule(rule)
    #expect(!transport.available)
    await #expect(throws: ShaarNetworkRuleError.self) {
      try await transport.apply([resolved], to: owner)
    }
    let stream = panel.messages(for: owner)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .streamAvailable)
    #expect(transport.available)
    try await transport.apply([resolved], to: owner)
    let submitted = try #require(requester.requests.last)
    #expect(submitted.0 == .panelNetworkRules)
    #expect(submitted.1 == owner)
    #expect(submitted.2["leaseID"] as? UInt32 == 7)
    let rows = try #require(submitted.2["rules"] as? [[String: Any]])
    #expect(
      rows.first?["bodyBase64"] as? String == Data("fixture response".utf8).base64EncodedString())
    let other = SiteControlTarget(tabID: UUID(), profileID: owner.profileID, url: owner.url)
    await #expect(throws: ShaarNetworkRuleError.self) {
      try await transport.apply([], to: other)
    }
    _ = panel.messages(for: other)
    await #expect(throws: ShaarNetworkRuleError.self) {
      try await transport.apply([], to: owner)
    }
  }

  private func request() -> ShaarNetworkRequest {
    ShaarNetworkRequest(
      id: "request-1", method: "GET", url: "http://localhost:3000/api",
      status: 200, mimeType: nil, encodedBytes: nil, startedAt: 0,
      respondedAt: nil, completedAt: nil, failure: nil,
      requestHeaders: [], responseHeaders: [], payload: nil, responseBody: nil)
  }

  private func target() -> SiteControlTarget {
    SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000")!)
  }
}
