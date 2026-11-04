// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import Testing

@testable import ShaarEngineABI

private actor FakeSiteDataEngine: ShaarSiteDataTransport {
  struct Call: Equatable {
    let profileID: UUID
    let operation: ShaarSiteDataOperation
    let arguments: Data
  }
  var calls: [Call] = []
  var response = Data()

  func setResponse(_ value: String) { response = Data(value.utf8) }
  func submit(profileID: UUID, operation: ShaarSiteDataOperation, arguments: Data) async throws
    -> Data
  {
    calls.append(Call(profileID: profileID, operation: operation, arguments: arguments))
    return response
  }
  func lastCall() -> Call? { calls.last }
}

private struct SiteDataSymbols: ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer? {
    guard named == "shaar_submit" else { return nil }
    let function =
      fakeSiteDataSubmit
      as @convention(c) (
        OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
        shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<shaar_error>?
      ) -> shaar_error_code
    return unsafeBitCast(function, to: UnsafeRawPointer.self)
  }
}

private struct SiteDataProfileResolver: ShaarStorageKeychainProfileResolving, @unchecked Sendable {
  let scope: shaar_scope
  func resolve(profileID: UUID) async throws -> ShaarStorageKeychainNativeProfile {
    ShaarStorageKeychainNativeProfile(engine: OpaquePointer(bitPattern: 0x44)!, scope: scope)
  }
}

private final class SiteDataCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: UInt32?
  private var profile: UInt?
  func record(_ scope: shaar_scope, _ operation: shaar_operation) {
    lock.lock()
    self.operation = operation.rawValue
    profile = scope.profile.map(UInt.init(bitPattern:))
    lock.unlock()
  }
  var snapshot: (UInt32?, UInt?) {
    lock.lock()
    defer { lock.unlock() }
    return (operation, profile)
  }
}

private let siteDataCapture = SiteDataCapture()

@_cdecl("fake_shaar_site_data_submit")
private func fakeSiteDataSubmit(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ arguments: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ context: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine != nil, window == nil, tab == nil, scope.private_session == nil,
    let reply, let context
  else { return SHAAR_INVALID_ARGUMENT }
  siteDataCapture.record(scope, operation)
  let address = UInt(bitPattern: context)
  DispatchQueue.global().async {
    let payload = Data(#"{"schemaVersion":1,"origins":[]}"#.utf8)
    payload.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: CChar.self)
      var result = shaar_result(
        size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
        error: shaar_error(
          size: UInt32(MemoryLayout<shaar_error>.size), code: SHAAR_OK,
          platform_code: 0, message: shaar_bytes(data: nil, size: 0)),
        payload_json: shaar_bytes(data: bytes.baseAddress, size: bytes.count))
      reply(UnsafeMutableRawPointer(bitPattern: address), &result)
    }
  }
  return SHAAR_OK
}

struct SiteDataTests {
  @Test func concreteTransportSubmitsOnlyTheExactRegularProfileScope() async throws {
    let handle = OpaquePointer(bitPattern: 0x11)!
    let resolver = SiteDataProfileResolver(
      scope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size), profile: handle, private_session: nil))
    let transport = try ShaarSiteDataABITransport(
      resolver: SiteDataSymbols(), profileResolver: resolver)
    let adapter = ShaarSiteDataAdapter(
      profileID: UUID(), implementation: .shaar, transport: transport)
    #expect(try await adapter.origins().isEmpty)
    let call = siteDataCapture.snapshot
    #expect(call.0 == ShaarSiteDataOperation.settingsOrigins.rawValue)
    #expect(call.1 == UInt(bitPattern: handle))

    let privateResolver = SiteDataProfileResolver(
      scope: shaar_scope(
        size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
        private_session: OpaquePointer(bitPattern: 0x22)))
    let privateTransport = try ShaarSiteDataABITransport(
      resolver: SiteDataSymbols(), profileResolver: privateResolver)
    await #expect(throws: ShaarSiteDataError.wrongProfile) {
      try await privateTransport.submit(
        profileID: UUID(), operation: .settingsOrigins,
        arguments: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }

  @Test func eachSiteDataRequestCarriesTheSelectedProfile() async throws {
    let fake = FakeSiteDataEngine()
    let selected = UUID()
    let adapter = ShaarSiteDataAdapter(profileID: selected, implementation: .shaar, transport: fake)
    await fake.setResponse("{\"schemaVersion\":1,\"origins\":[]}")
    _ = try await adapter.origins()
    let call = try #require(await fake.lastCall())
    #expect(call.profileID == selected)
    #expect(call.operation == .settingsOrigins)
  }

  @Test func selectionPreservesArdiaDefaultAndValidatesSettingsPayload() async throws {
    let fake = FakeSiteDataEngine()
    #expect(
      ShaarSiteDataAdapter.selected(profileID: UUID(), implementation: .ardia, transport: fake)
        == nil)
    #expect(
      ShaarSiteDataAdapter.selected(
        profileID: UUID(), implementation: .shippingDefault, transport: fake) == nil)
    let adapter = ShaarSiteDataAdapter(profileID: UUID(), implementation: .shaar, transport: fake)
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

  @Test func resetAndClearOperationsUseTypedSchemas() async throws {
    let fake = FakeSiteDataEngine()
    let adapter = ShaarSiteDataAdapter(profileID: UUID(), implementation: .shaar, transport: fake)
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
    let adapter = ShaarSiteDataAdapter(profileID: UUID(), implementation: .shaar, transport: fake)
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
    let adapter = ShaarSiteDataAdapter(profileID: UUID(), implementation: .shaar, transport: fake)
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
}
