// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeSiteDataEngine: ShaarSiteDataTransport {
  struct Call: Equatable {
    let operation: ShaarSiteDataOperation
    let scope: ShaarSiteDataScope
    let windowID: String?
    let tabID: String?
    let arguments: Data
  }
  var calls: [Call] = []
  var response = Data()
  var failure: Error?

  func setResponse(_ value: String) { response = Data(value.utf8) }
  func setFailure(_ error: Error?) { failure = error }
  func submit(
    operation: ShaarSiteDataOperation, scope: ShaarSiteDataScope,
    windowID: String?, tabID: String?, arguments: Data
  ) async throws -> Data {
    calls.append(
      Call(
        operation: operation, scope: scope, windowID: windowID, tabID: tabID,
        arguments: arguments))
    if let failure { throw failure }
    return response
  }
  func lastCall() -> Call? { calls.last }
}

struct SiteDataTests {
  private let regularScope = ShaarSiteDataScope(profileID: "profile-1")

  @Test func selectionPreservesArdiaDefaultAndValidatesSettingsPayload() async throws {
    let fake = FakeSiteDataEngine()
    #expect(
      ShaarSiteDataAdapter.selected(implementation: .ardia, scope: regularScope, transport: fake)
        == nil)
    #expect(
      ShaarSiteDataAdapter.selected(
        implementation: .shippingDefault, scope: regularScope, transport: fake) == nil)
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, scope: regularScope, transport: fake)
    await fake.setResponse(
      """
      {"schemaVersion":1,"settings":{"camera":{"value":"ask","isDefault":true}}}
      """)
    let values = try await adapter.settings(origin: "HTTPS://Example.com/")
    #expect(values["camera"] == ShaarSiteSetting(value: .ask, isDefault: true))
    let call = await fake.lastCall()
    #expect(call?.operation == .settingsGet)
    #expect(call?.scope == regularScope)
    let arguments = try #require(
      JSONSerialization.jsonObject(with: call?.arguments ?? Data()) as? [String: Any])
    #expect(arguments["origin"] as? String == "https://example.com")
  }

  @Test func resetAndClearOperationsUseTypedSchemas() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, scope: regularScope, transport: fake)
    await fake.setResponse("{\"schemaVersion\":1,\"resetCount\":2}")
    #expect(try await adapter.reset(origin: "https://example.com") == 2)
    await fake.setResponse(
      "{\"schemaVersion\":1,\"clearedTypes\":[\"cache\",\"siteData\"],\"complete\":true}")
    #expect(
      try await adapter.clearBrowsingData(types: ["siteData", "cache"]) == ["cache", "siteData"])
    #expect(await fake.lastCall()?.operation == .browsingDataClear)
  }

  @Test func rejectsNonOriginAndMalformedResult() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, scope: regularScope, transport: fake)
    await #expect(throws: ShaarSiteDataError.invalidOrigin) {
      try await adapter.settings(origin: "https://example.com/path")
    }
    await fake.setResponse("{\"schemaVersion\":1,\"resetCount\":-1}")
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.reset(origin: "https://example.com")
    }
  }

  @Test func cookieOperationsDecodePolicyAndRequireCompletion() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(
      implementation: .shaar, scope: regularScope, windowID: "window-1", tabID: "tab-1",
      transport: fake)
    await fake.setResponse("{\"schemaVersion\":1,\"blocked\":true,\"managed\":false}")
    #expect(
      try await adapter.setThirdPartyCookiesBlocked(true)
        == ShaarThirdPartyCookiePolicy(blocked: true, managed: false))
    #expect(await fake.lastCall()?.operation == .thirdPartyCookiesSet)

    await fake.setResponse("{\"schemaVersion\":1,\"complete\":true}")
    try await adapter.clearSiteData(origin: "https://example.com")
    #expect(await fake.lastCall()?.operation == .siteDataClear)
    try await adapter.clearSelectedTabCookies(origin: "https://example.com")
    #expect(await fake.lastCall()?.operation == .siteCookiesClear)
  }

  @Test func eventRoutingRequiresExactProfileAndPrivateSession() {
    let regular = ShaarSiteDataAdapter(
      implementation: .shaar, scope: regularScope, transport: FakeSiteDataEngine())
    let event = ShaarCopiedEvent(
      sequence: 1, kind: 12, profileID: Data("profile-1".utf8), sessionID: Data(),
      windowID: Data(), tabID: Data(),
      payloadJSON: Data("{\"kind\":\"settingsChanged\",\"schemaVersion\":1}".utf8))
    var received: ShaarSiteDataEvent?
    #expect(regular.receive(event) { received = $0 })
    #expect(received?.kind == .settingsChanged)
    #expect(received?.privateSessionID == nil)

    let privateAdapter = ShaarSiteDataAdapter(
      implementation: .shaar,
      scope: ShaarSiteDataScope(profileID: "profile-1", privateSessionID: "session-1"),
      transport: FakeSiteDataEngine())
    #expect(!privateAdapter.receive(event) { _ in Issue.record("regular event crossed into OTR") })
  }

  @Test func managedPolicyFailureRemainsTyped() async {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(
      implementation: .shaar, scope: regularScope, transport: fake)
    await fake.setFailure(
      ShaarEngineError.status(.policyBlocked, platformCode: 0, message: "managed"))
    await #expect(
      throws: ShaarEngineError.status(.policyBlocked, platformCode: 0, message: "managed")
    ) {
      try await adapter.setThirdPartyCookiesBlocked(true)
    }
  }
}
