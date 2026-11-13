// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABIC
import Testing

@testable import ShaarEngineABI

private final class FakeNavigationEngine: ShaarNavigationSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: ShaarNavigationRequest?

  var request: ShaarNavigationRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }

  func submit(
    _ request: ShaarNavigationRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    lock.lock()
    storedRequest = request
    lock.unlock()
    Task { completion(.success(Data("{}".utf8))) }
    return 77
  }
}

private struct FakeHandleResolver: ShaarNavigationHandleResolving {
  func resolve(
    scope: ShaarNavigationScope, windowID: String, tabID: String
  ) throws -> ShaarABINativeHandles {
    let profile = OpaquePointer(bitPattern: 0x11)!
    let window = OpaquePointer(bitPattern: 0x22)!
    let tab = OpaquePointer(bitPattern: 0x33)!
    let engine = OpaquePointer(bitPattern: 0x44)!
    let nativeScope = shaar_scope(
      size: UInt32(MemoryLayout<shaar_scope>.size), profile: profile, private_session: nil)
    return ShaarABINativeHandles(
      engine: engine, scope: nativeScope, window: window, tab: tab)
  }
}

@_cdecl("fake_shaar_navigation_submit")
private func fakeShaarNavigationSubmit(
  _ engine: OpaquePointer?, _ scope: shaar_scope, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ operation: shaar_operation, _ args: shaar_bytes, _ requestID: UInt64,
  _ reply: shaar_reply_fn?, _ replyContext: UnsafeMutableRawPointer?,
  _ immediateError: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard let reply, let replyContext else { return shaar_error_code(rawValue: 1) }
  let replyContextAddress = UInt(bitPattern: replyContext)
  let response = operation.rawValue == ShaarNavigationOperation.reload.rawValue
    ? "{\"schemaVersion\":true}" : "{\"schemaVersion\":1}"
  DispatchQueue.global().async {
    deliverFakeNavigationReply(
      reply, contextAddress: replyContextAddress, requestID: requestID, response: response)
  }
  return shaar_error_code(rawValue: 0)
}

private func deliverFakeNavigationReply(
  _ reply: shaar_reply_fn, contextAddress: UInt, requestID: UInt64,
  response: String = "{\"schemaVersion\":1}"
) {
  let context = UnsafeMutableRawPointer(bitPattern: contextAddress)!
  let responseData = Data(response.utf8)
  responseData.withUnsafeBytes { rawBuffer in
    let payload = rawBuffer.bindMemory(to: CChar.self)
    let resultError = shaar_error(
      size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
      platform_code: 0, message: shaar_bytes(data: nil, size: 0))
    let resultPayload = shaar_bytes(data: payload.baseAddress, size: payload.count)
    var result = shaar_result(
      size: UInt32(MemoryLayout<shaar_result>.size), request_id: requestID,
      error: resultError, payload_json: resultPayload)
    reply(context, &result)
  }
}

private struct FakeNavigationSymbols: ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer? {
    guard named == "shaar_submit" else { return nil }
    let function =
      fakeShaarNavigationSubmit
      as @convention(c) (
        OpaquePointer?, shaar_scope, OpaquePointer?, OpaquePointer?, shaar_operation,
        shaar_bytes, UInt64, shaar_reply_fn?, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<shaar_error>?
      ) -> shaar_error_code
    return unsafeBitCast(function, to: UnsafeRawPointer.self)
  }
}

@Suite("Shaar navigation adapter")
struct ShaarNavigationAdapterTests {
  @Test func commandUsesExactScopeAndVersionedPayload() throws {
    let fake = FakeNavigationEngine()
    let adapter = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake))
    let requestID = try adapter.submit(
      .navigate(url: "https://example.test/path", userInitiated: true),
      scope: ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a"),
      windowID: "window-a", tabID: "tab-a", completion: { _ in })

    #expect(requestID == 77)
    #expect(fake.request?.operation == .navigate)
    #expect(
      fake.request?.scope == ShaarNavigationScope(profileID: "profile-a", sessionID: "private-a"))
    #expect(fake.request?.windowID == "window-a")
    #expect(fake.request?.tabID == "tab-a")
    let request = try #require(fake.request)
    let payload = try #require(
      JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(payload["schemaVersion"] as? Int == 1)
    #expect(payload["url"] as? String == "https://example.test/path")
    #expect(payload["userInitiated"] as? Bool == true)
  }

  @Test(arguments: [
    (ShaarNavigationCommand.goBack, "back"),
    (.goForward, "forward"),
  ])
  func historyDirectionIsExplicit(command: ShaarNavigationCommand, direction: String) throws {
    let fake = FakeNavigationEngine()
    _ = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake)).submit(
      command, scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
      completion: { _ in })
    let request = try #require(fake.request)
    let payload = try #require(
      JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
    #expect(payload["direction"] as? String == direction)
  }

  @Test func reloadModesAndStopHaveSeparateSchemas() throws {
    for (command, operation, fieldValue) in [
      (ShaarNavigationCommand.reload, ShaarNavigationOperation.reload, "normal"),
      (.reloadBypassingCache, .reload, "bypass_cache"),
      (.stop, .stop, ""),
    ] {
      let fake = FakeNavigationEngine()
      _ = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: fake)).submit(
        command, scope: ShaarNavigationScope(profileID: "p"), windowID: "w", tabID: "t",
        completion: { _ in })
      #expect(fake.request?.operation == operation)
      let request = try #require(fake.request)
      let payload = try #require(
        JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
      #expect(payload["mode"] as? String == (fieldValue.isEmpty ? nil : fieldValue))
    }
  }

  @Test func adapterRequiresEveryOwnerAndRejectsEmptyPrivateSession() throws {
    let adapter = try #require(
      ShaarNavigationAdapter(implementation: .shaar, transport: FakeNavigationEngine()))
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: ""), windowID: "w", tabID: "t",
        completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: "p", sessionID: ""), windowID: "w",
        tabID: "t", completion: { _ in })
    }
    #expect(throws: ShaarEngineError.self) {
      try adapter.submit(
        .stop, scope: ShaarNavigationScope(profileID: "p"), windowID: "", tabID: "t",
        completion: { _ in })
    }
  }

  @Test func snapshotRejectsUnknownFieldsRedactsCredentialsAndDropsStaleGeneration() throws {
    let raw = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":"https://user:secret@example.test/path","title":"Page","loading":false,"canGoBack":true,"canGoForward":false,"sameDocument":false}"#
        .utf8)
    let snapshot = try ShaarNavigationSnapshot.decode(raw)
    #expect(snapshot.url == "https://example.test/path")

    var generations = ShaarNavigationGeneration()
    let firstAccepted = generations.accept(snapshot)
    let duplicateAccepted = generations.accept(snapshot)
    #expect(firstAccepted)
    #expect(!duplicateAccepted)
    generations.close()
    let afterCloseAccepted = generations.accept(snapshot)
    #expect(!afterCloseAccepted)

    let unknown = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"state","navigationID":"nav-2","generation":5,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"secret":"x"}"#
        .utf8)
    #expect(throws: ShaarEngineError.self) { try ShaarNavigationSnapshot.decode(unknown) }
  }

  @Test func snapshotPreservesTypedNavigationFailure() throws {
    let raw = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-2","generation":2,"url":"https://example.test","title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":-105,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#
        .utf8)
    let snapshot = try ShaarNavigationSnapshot.decode(raw)
    #expect(
      snapshot.failure
        == .init(
          netError: -105, isMainFrame: true, descriptionCode: "navigation_failed"))
  }

  @Test func snapshotRejectsEmptyIDAndZeroGeneration() {
    let valid =
      #"{"kind":"navigation","schemaVersion":1,"phase":"state","navigationID":"nav-1","generation":1,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false}"#
    for payload in [
      valid.replacingOccurrences(of: #""navigationID":"nav-1""#, with: #""navigationID":"""#),
      valid.replacingOccurrences(of: #""generation":1"#, with: #""generation":0"#),
    ] {
      #expect(throws: ShaarEngineError.self) {
        try ShaarNavigationSnapshot.decode(Data(payload.utf8))
      }
    }
  }

  @Test func snapshotRejectsNumericBooleanFields() {
    let base =
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false}"#
    let failure =
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":-105,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#
    let invalid = [
      base.replacingOccurrences(of: #""loading":false"#, with: #""loading":1"#),
      base.replacingOccurrences(of: #""canGoBack":false"#, with: #""canGoBack":0"#),
      base.replacingOccurrences(of: #""canGoForward":false"#, with: #""canGoForward":1"#),
      base.replacingOccurrences(of: #""sameDocument":false"#, with: #""sameDocument":0"#),
      failure.replacingOccurrences(of: #""isMainFrame":true"#, with: #""isMainFrame":1"#),
    ]
    for payload in invalid {
      #expect(throws: ShaarEngineError.self) {
        try ShaarNavigationSnapshot.decode(Data(payload.utf8))
      }
    }
  }

  @Test func snapshotIntegerFieldsRejectBooleansAndFractions() {
    let base =
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false}"#
    let failures =
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":-105,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#
    let invalid = [
      base.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":true"#),
      base.replacingOccurrences(of: #""generation":4"#, with: #""generation":true"#),
      base.replacingOccurrences(of: #""generation":4"#, with: #""generation":4.5"#),
      failures.replacingOccurrences(of: #""netError":-105"#, with: #""netError":true"#),
      failures.replacingOccurrences(of: #""netError":-105"#, with: #""netError":-105.5"#),
    ]
    for payload in invalid {
      #expect(throws: ShaarEngineError.self) {
        try ShaarNavigationSnapshot.decode(Data(payload.utf8))
      }
    }
  }

  @Test func snapshotBooleanFieldsRejectNumericValues() {
    let base =
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false}"#
    for field in ["loading", "canGoBack", "canGoForward", "sameDocument"] {
      for numeric in ["0", "1"] {
        let payload = base.replacingOccurrences(
          of: #""\#(field)":false"#, with: #""\#(field)":\#(numeric)"#)
        #expect(throws: ShaarEngineError.self) {
          try ShaarNavigationSnapshot.decode(Data(payload.utf8))
        }
      }
    }
    let failed =
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":-105,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#
    let numericMainFrame = failed.replacingOccurrences(
      of: #""isMainFrame":true"#, with: #""isMainFrame":1"#)
    #expect(throws: ShaarEngineError.self) {
      try ShaarNavigationSnapshot.decode(Data(numericMainFrame.utf8))
    }
  }

  @Test func snapshotPreservesLargeIntegerFieldsExactly() throws {
    let rawInteger = 9_007_199_254_740_993
    let rawGeneration = UInt64(rawInteger)
    let payload = Data(
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-1","generation":9007199254740993,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":9007199254740993,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#.utf8)

    let snapshot = try ShaarNavigationSnapshot.decode(payload)
    #expect(snapshot.generation == rawGeneration)
    #expect(snapshot.failure?.netError == rawInteger)
  }

  @Test func snapshotBooleanFieldsRejectNumericJSONValues() {
    let base =
      #"{"kind":"navigation","schemaVersion":1,"phase":"committed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false}"#
    let failure =
      #"{"kind":"navigation","schemaVersion":1,"phase":"failed","navigationID":"nav-1","generation":4,"url":null,"title":null,"loading":false,"canGoBack":false,"canGoForward":false,"sameDocument":false,"failure":{"netError":-105,"isMainFrame":true,"descriptionCode":"navigation_failed"}}"#
    let invalid = [
      base.replacingOccurrences(of: #""loading":false"#, with: #""loading":1"#),
      base.replacingOccurrences(of: #""canGoBack":false"#, with: #""canGoBack":0"#),
      base.replacingOccurrences(of: #""canGoForward":false"#, with: #""canGoForward":1"#),
      base.replacingOccurrences(of: #""sameDocument":false"#, with: #""sameDocument":0"#),
      failure.replacingOccurrences(of: #""isMainFrame":true"#, with: #""isMainFrame":1"#),
    ]
    for payload in invalid {
      #expect(throws: ShaarEngineError.self) {
        try ShaarNavigationSnapshot.decode(Data(payload.utf8))
      }
    }
  }

  @Test func shippingChoiceUsesShaar() {
    #expect(ShaarEngineImplementation.shippingDefault == .shaar)
    #expect(ShaarNavigationAdapter(transport: FakeNavigationEngine()) != nil)
  }

  @Test func concreteTransportCallsFakeABISymbolAndCopiesAsyncResult() async throws {
    let transport = try ShaarNavigationABITransport(
      resolver: FakeNavigationSymbols(), handleResolver: FakeHandleResolver())
    let adapter = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: transport))
    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        _ = try adapter.submit(
          .stop, scope: ShaarNavigationScope(profileID: "profile"), windowID: "window",
          tabID: "tab"
        ) { result in
          continuation.resume(with: result.mapError { $0 as Error })
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    #expect(String(decoding: response, as: UTF8.self) == "{\"schemaVersion\":1}")
  }

  @Test func concreteTransportRejectsBooleanReplySchemaVersion() async throws {
    let transport = try ShaarNavigationABITransport(
      resolver: FakeNavigationSymbols(), handleResolver: FakeHandleResolver())
    let adapter = try #require(ShaarNavigationAdapter(implementation: .shaar, transport: transport))
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<Data, ShaarEngineError>, Never>) in
      do {
        _ = try adapter.submit(
          .reload, scope: ShaarNavigationScope(profileID: "profile"), windowID: "window",
          tabID: "tab", completion: { continuation.resume(returning: $0) })
      } catch {
        continuation.resume(returning: .failure(error as? ShaarEngineError ?? .invalidEvent("submit failed")))
      }
    }
    guard case .failure(.invalidEvent("invalid navigation result payload")) = result else {
      Issue.record("Expected boolean schemaVersion reply to be rejected, got \(result)")
      return
    }
  }
}
