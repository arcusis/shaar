// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeSiteDataEngine: ShaarSiteDataTransport {
  struct Call: Equatable {
    let operation: ShaarSiteDataOperation
    let arguments: Data
  }
  var calls: [Call] = []
  var response = Data()

  func setResponse(_ value: String) { response = Data(value.utf8) }
  func submit(operation: ShaarSiteDataOperation, arguments: Data) async throws -> Data {
    calls.append(Call(operation: operation, arguments: arguments))
    return response
  }
  func lastCall() -> Call? { calls.last }
}

struct SiteDataTests {
  @Test func selectionUsesShaarDefaultAndValidatesSettingsPayload() async throws {
    let fake = FakeSiteDataEngine()
    #expect(ShaarSiteDataAdapter.selected(implementation: .shaar, transport: fake) != nil)
    #expect(ShaarSiteDataAdapter.selected(implementation: .shippingDefault, transport: fake) != nil)
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await fake.setResponse(
      """
      {"schemaVersion":1,"settings":{"camera":{"value":"ask","isDefault":true}}}
      """)
    let values = try await adapter.settings(origin: "HTTPS://Example.com/")
    #expect(values["camera"] == ShaarSiteSetting(value: .ask, isDefault: true))
    let call = await fake.lastCall()
    #expect(call?.operation == .settingsGet)
    let arguments = try #require(
      JSONSerialization.jsonObject(with: call?.arguments ?? Data()) as? [String: Any])
    #expect(arguments["origin"] as? String == "https://example.com")
  }

  @Test func settingsAcceptRememberedMidiAndProtocolHandlers() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await fake.setResponse(
      """
      {"schemaVersion":1,"settings":{"midi":{"value":"allow","isDefault":false},"protocolHandlers":{"value":"allow","isDefault":false}}}
      """)
    let values = try await adapter.settings(origin: "https://example.com")
    #expect(values["midi"] == ShaarSiteSetting(value: .allow, isDefault: false))
    #expect(values["protocolHandlers"] == ShaarSiteSetting(value: .allow, isDefault: false))
    let callsAfterRead = await fake.calls.count
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.set(origin: "https://example.com", type: "protocolHandlers", value: .allow)
    }
    #expect(await fake.calls.count == callsAfterRead)
  }

  @Test func settingResponseRejectsNumericBooleanDefaultFlag() async throws {
    let fake = FakeSiteDataEngine()
    await fake.setResponse(
      #"{"schemaVersion":1,"settings":{"camera":{"value":"ask","isDefault":1}}}"#)
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      _ = try await adapter.settings(origin: "https://example.com")
    }
  }

  @Test func clearResponseRejectsNumericBooleanCompletion() async throws {
    let fake = FakeSiteDataEngine()
    await fake.setResponse(#"{"schemaVersion":1,"complete":1}"#)
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.clearSiteData(origin: "https://example.com")
    }
  }

  @Test func cookieDecoderRejectsNumericBooleanFlags() throws {
    let valid: [String: Any] = [
      "name": "sid", "value": "v", "domain": "example.com", "path": "/",
      "secure": true, "httpOnly": false, "sameSite": "Lax", "expiresUnixMs": NSNull(),
      "partitionSite": "https://example.com", "partitionCrossSite": true,
      "sourceScheme": 2, "sourcePort": 443,
    ]
    for key in ["secure", "httpOnly", "partitionCrossSite"] {
      var invalid = valid
      invalid[key] = 1
      #expect(ShaarSiteCookie(dictionary: invalid) == nil)
    }
  }

  @Test func resetAndClearOperationsUseTypedSchemas() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
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
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
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
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
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

  @Test func siteDataResultBooleansRejectNumericSubstitutes() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)

    await fake.setResponse(
      #"{"schemaVersion":1,"settings":{"camera":{"value":"ask","isDefault":1}}}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.settings(origin: "https://example.com")
    }

    await fake.setResponse(#"{"schemaVersion":1,"value":"allow","isDefault":0}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.set(origin: "https://example.com", type: "camera", value: .allow)
    }

    await fake.setResponse(#"{"schemaVersion":1,"blocked":1,"managed":true}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.thirdPartyCookiePolicy()
    }
    await fake.setResponse(#"{"schemaVersion":1,"blocked":false,"managed":0}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.thirdPartyCookiePolicy()
    }

    await fake.setResponse(#"{"schemaVersion":1,"complete":1}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.clearSiteData(origin: "https://example.com")
    }
    await fake.setResponse(
      #"{"schemaVersion":1,"clearedTypes":["cache"],"complete":1}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.clearBrowsingData(types: ["cache"])
    }
    await fake.setResponse(#"{"schemaVersion":1,"complete":1}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.clearSelectedTabCookies(origin: "https://example.com")
    }

    let cookie = try #require(ShaarSiteCookie(dictionary: [
      "name": "sid", "value": "abc", "domain": "example.com", "path": "/",
      "secure": true, "httpOnly": true, "sameSite": "Lax",
      "expiresUnixMs": NSNull(), "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
      "sourceScheme": 2, "sourcePort": 443,
    ]))
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      try await adapter.setCookie(
        cookie, value: "updated", secure: true, httpOnly: false, sameSite: .lax,
        origin: "https://example.com")
    }
  }

  @Test func cookiePolicyRejectsNumericBooleanSubstitutes() async throws {
    let fake = FakeSiteDataEngine()
    await fake.setResponse("{\"schemaVersion\":1,\"blocked\":1,\"managed\":0}")
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      _ = try await adapter.thirdPartyCookiePolicy()
    }
  }

  @Test func individualCookieOperationsUseSiteDataAndValidateIdentity() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await fake.setResponse(
      #"{"schemaVersion":1,"cookies":[{"name":"sid","value":"abc","domain":"example.com","path":"/","secure":true,"httpOnly":true,"sameSite":"Lax","expiresUnixMs":null,"partitionSite":null,"partitionCrossSite":null,"sourceScheme":2,"sourcePort":443}]}"#
    )
    let cookie = try #require(try await adapter.cookies(origin: "https://example.com").first)
    #expect(cookie.name == "sid" && cookie.httpOnly && cookie.sameSite == .lax)
    #expect(await fake.lastCall()?.operation == .siteCookieItems)

    await fake.setResponse(#"{"schemaVersion":1,"complete":true}"#)
    try await adapter.setCookie(
      cookie, value: "updated", secure: true, httpOnly: false, sameSite: .strict,
      origin: "https://example.com")
    let setCall = try #require(await fake.lastCall())
    #expect(setCall.operation == .siteCookieSet)
    let setArgs = try #require(
      JSONSerialization.jsonObject(with: setCall.arguments) as? [String: Any])
    #expect(setArgs["name"] as? String == "sid")
    #expect(setArgs["value"] as? String == "updated")
    try await adapter.deleteCookie(cookie, origin: "https://example.com")
    #expect(await fake.lastCall()?.operation == .siteCookieDelete)
  }

  @Test func cookieDecoderRejectsBooleanIntegerFields() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    let cookie =
      #"{"name":"sid","value":"abc","domain":"example.com","path":"/","secure":true,"httpOnly":true,"sameSite":"Lax","expiresUnixMs":null,"partitionSite":"https://example.com","partitionCrossSite":true,"sourceScheme":2,"sourcePort":443}"#
    for invalid in [
      cookie.replacingOccurrences(of: #""sourcePort":443"#, with: #""sourcePort":true"#),
      cookie.replacingOccurrences(of: #""sourceScheme":2"#, with: #""sourceScheme":true"#),
      cookie.replacingOccurrences(of: #""expiresUnixMs":null"#, with: #""expiresUnixMs":true"#),
      cookie.replacingOccurrences(of: #""secure":true"#, with: #""secure":1"#),
      cookie.replacingOccurrences(of: #""httpOnly":true"#, with: #""httpOnly":0"#),
      cookie.replacingOccurrences(
        of: #""partitionCrossSite":true"#, with: #""partitionCrossSite":1"#),
    ] {
      await fake.setResponse("{\"schemaVersion\":1,\"cookies\":[\(invalid)]}")
      await #expect(throws: ShaarSiteDataError.malformedResponse) {
        _ = try await adapter.cookies(origin: "https://example.com")
      }
    }
  }

  @Test func cookieDecoderRejectsNumericBooleanFields() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    let cookie =
      #"{"name":"sid","value":"abc","domain":"example.com","path":"/","secure":true,"httpOnly":true,"sameSite":"Lax","expiresUnixMs":null,"partitionSite":"https://example.com","partitionCrossSite":false,"sourceScheme":2,"sourcePort":443}"#
    for invalid in [
      cookie.replacingOccurrences(of: #""secure":true"#, with: #""secure":1"#),
      cookie.replacingOccurrences(of: #""httpOnly":true"#, with: #""httpOnly":0"#),
      cookie.replacingOccurrences(of: #""partitionCrossSite":false"#, with: #""partitionCrossSite":1"#),
    ] {
      await fake.setResponse("{\"schemaVersion\":1,\"cookies\":[\(invalid)]}")
      await #expect(throws: ShaarSiteDataError.malformedResponse) {
        _ = try await adapter.cookies(origin: "https://example.com")
      }
    }
  }

  @Test func resetRejectsBooleanCount() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
    await fake.setResponse(#"{"schemaVersion":1,"resetCount":true}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      _ = try await adapter.reset(origin: "https://example.com")
    }
  }

  @Test func siteDataResponsesRejectBooleanSchemaVersion() async throws {
    let fake = FakeSiteDataEngine()
    await fake.setResponse(#"{"schemaVersion":true,"resetCount":0}"#)
    await #expect(throws: ShaarSiteDataError.malformedResponse) {
      _ = try await ShaarSiteDataAdapter(implementation: .shaar, transport: fake)
        .reset(origin: "https://example.test")
    }
  }
}
