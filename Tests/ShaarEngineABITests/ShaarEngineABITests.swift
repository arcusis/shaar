// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@_cdecl("fake_shaar_abi_major")
private func fakeShaarABIMajor() -> UInt32 { 1 }

@_cdecl("fake_shaar_abi_major_mismatch")
private func fakeShaarABIMajorMismatch() -> UInt32 { 9 }

@_cdecl("fake_shaar_engine_create")
private func fakeShaarEngineCreate() -> Int32 { 0 }

private struct FakeEngine: ShaarSymbolResolving {
  let mismatchedMajor: Bool

  init(mismatchedMajor: Bool = false) { self.mismatchedMajor = mismatchedMajor }

  func symbol(named: String) -> UnsafeRawPointer? {
    switch named {
    case "shaar_abi_major":
      if mismatchedMajor {
        return unsafeBitCast(
          fakeShaarABIMajorMismatch as @convention(c) () -> UInt32, to: UnsafeRawPointer.self)
      }
      return unsafeBitCast(
        fakeShaarABIMajor as @convention(c) () -> UInt32, to: UnsafeRawPointer.self)
    case "shaar_engine_create":
      return unsafeBitCast(
        fakeShaarEngineCreate as @convention(c) () -> Int32, to: UnsafeRawPointer.self)
    default: return nil
    }
  }
}

@MainActor private final class FakePrivateSessionsEngine: ShaarPrivateSessionsEngine {
  var calls: [String] = []
  func openSession(profileID: Data, sessionID: Data) throws -> UInt {
    calls.append("open-session")
    return 11
  }
  func closeSession(_ handle: UInt) throws { calls.append("close-session-\(handle)") }
  func openWindow(session: UInt, windowID: Data) throws -> UInt {
    calls.append("open-window")
    return 22
  }
  func closeWindow(_ handle: UInt) throws { calls.append("close-window-\(handle)") }
  func openTab(session: UInt, window: UInt, tabID: Data, url: Data, foreground: Bool) throws -> UInt
  {
    calls.append("open-tab-\(foreground)")
    return 33
  }
  func closeTab(_ handle: UInt) throws { calls.append("close-tab-\(handle)") }
  func activateTab(session: UInt, window: UInt, tab: UInt, requestID: UInt64) throws {
    calls.append("activate-\(requestID)")
  }
}

@Suite("Shaar engine ABI step 0")
struct ShaarEngineABITests {
  @Test func fakeEngineLoadsMatchingMajorAndRequiresBothExports() throws {
    let loader = try ShaarEngineLoader(resolver: FakeEngine())
    #expect(loader.currentMajor() == 1)
    #expect(loader.implementation == .shaar)
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
  }

  @Test func loaderRejectsMismatchedMajorWithTypedError() {
    #expect(throws: ShaarEngineError.unsupportedABI(expected: 1, actual: 9)) {
      try ShaarEngineLoader(resolver: FakeEngine(mismatchedMajor: true))
    }
  }

  @Test func statusCodesMapToTypedSwiftErrors() throws {
    for status in ShaarStatusCode.allCases where status != .ok {
      #expect(throws: ShaarEngineError.status(status, platformCode: 7, message: "diagnostic")) {
        try ShaarStatusCode.decode(status.rawValue, platformCode: 7, message: "diagnostic")
      }
    }
    try ShaarStatusCode.decode(ShaarStatusCode.ok.rawValue)
    #expect(throws: ShaarEngineError.invalidStatusCode(99)) { try ShaarStatusCode.decode(99) }
  }

  @Test @MainActor func privateAdapterCarriesExplicitScopeAndRejectsMismatches() throws {
    let engine = FakePrivateSessionsEngine()
    #expect(ShaarPrivateSessionsAdapter.makeIfSelected(engine: engine) == nil)
    #expect(
      ShaarPrivateSessionsAdapter.makeIfSelected(implementation: .shaar, engine: engine) != nil)
    let adapter = ShaarPrivateSessionsAdapter(engine: engine)
    let profile = Data("profile-a".utf8)
    let session = Data("session-a".utf8)
    _ = try adapter.openSession(profileID: profile, sessionID: session)
    _ = try adapter.openWindow(sessionID: session, windowID: Data("window-a".utf8))
    try adapter.openTab(
      sessionID: session, windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      url: Data("about:blank".utf8), foreground: true)
    try adapter.activateTab(
      sessionID: session, windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      requestID: 7)
    #expect(engine.calls == ["open-session", "open-window", "open-tab-true", "activate-7"])
    #expect(
      throws: ShaarEngineError.status(
        .wrongSession, platformCode: 0, message: "window is outside private session")
    ) {
      try adapter.openTab(
        sessionID: Data("other-session".utf8), windowID: Data("window-a".utf8),
        tabID: Data("tab-b".utf8), url: Data("about:blank".utf8), foreground: false)
    }
    #expect(
      throws: ShaarEngineError.status(
        .conflict, platformCode: 0, message: "private tabs must close first")
    ) {
      try adapter.closeWindow(windowID: Data("window-a".utf8))
    }
    try adapter.closeTab(tabID: Data("tab-a".utf8))
    try adapter.closeWindow(windowID: Data("window-a".utf8))
    try adapter.closeSession(profileID: profile, sessionID: session)
    #expect(
      Array(engine.calls.suffix(3)) == ["close-tab-33", "close-window-22", "close-session-11"])
  }

  @Test @MainActor func privateEventRoutingRequiresAllFourIDs() {
    let adapter = ShaarPrivateSessionsAdapter(engine: FakePrivateSessionsEngine())
    let event = ShaarCopiedEvent(
      sequence: 4, kind: 5, profileID: Data("p".utf8), sessionID: Data("s".utf8),
      windowID: Data("w".utf8), tabID: Data("t".utf8), payloadJSON: Data("{}".utf8))
    var delivered = false
    #expect(
      adapter.routePrivateEvent(
        event, profileID: Data("p".utf8), sessionID: Data("s".utf8),
        windowID: Data("w".utf8), tabID: Data("t".utf8), handler: { _ in delivered = true }))
    #expect(delivered)
    #expect(
      !adapter.routePrivateEvent(
        event, profileID: Data("p".utf8), sessionID: Data("other".utf8),
        windowID: Data("w".utf8), tabID: Data("t".utf8), handler: { _ in delivered = false }))
    #expect(delivered)
  }

  @Test @MainActor func eventIsCopiedBeforeMainActorDispatch() async throws {
    var delivered: ShaarCopiedEvent?
    let dispatcher = ShaarEventDispatcher { delivered = $0 }
    let profile = Array("profile".utf8)
    let payload = Array("{\"kind\":\"tab\",\"schemaVersion\":1}".utf8)
    let event = profile.withUnsafeBufferPointer { profileBuffer in
      payload.withUnsafeBufferPointer { payloadBuffer in
        ShaarABIEvent(
          size: UInt32(MemoryLayout<ShaarABIEvent>.size), sequence: 42, kind: 5,
          profileID: ShaarBytes(
            data: profileBuffer.baseAddress.map {
              UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }, size: profile.count),
          sessionID: ShaarBytes(data: nil, size: 0), windowID: ShaarBytes(data: nil, size: 0),
          tabID: ShaarBytes(data: nil, size: 0),
          payloadJSON: ShaarBytes(
            data: payloadBuffer.baseAddress.map {
              UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }, size: payload.count))
      }
    }
    dispatcher.receive(event)
    for _ in 0..<20 where delivered == nil { await Task.yield() }
    #expect(delivered?.sequence == 42)
    #expect(delivered?.profileID == Data(profile))
    #expect(delivered?.payloadJSON == Data(payload))
  }

  @Test @MainActor func privateSessionsWithDistinctIDsCoexistPerProfile() throws {
    let engine = FakePrivateSessionsEngine()
    let adapter = ShaarPrivateSessionsAdapter(engine: engine)
    let profile = Data("profile-a".utf8)
    let first = try adapter.openSession(profileID: profile, sessionID: Data("session-a".utf8))
    let second = try adapter.openSession(profileID: profile, sessionID: Data("session-b".utf8))
    #expect(first.profileID == second.profileID)
    #expect(first.sessionID != second.sessionID)
    try adapter.closeSession(profileID: profile, sessionID: first.sessionID)
    _ = try adapter.openWindow(sessionID: second.sessionID, windowID: Data("window-b".utf8))
    #expect(engine.calls == ["open-session", "open-session", "close-session-11", "open-window"])
  }
}
