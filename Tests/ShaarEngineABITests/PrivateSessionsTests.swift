// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@MainActor private final class FakePrivateSessionsEngine: ShaarPrivateSessionsEngine {
  var calls: [String] = []
  var sessionHandle: UInt = 11
  var windowHandle: UInt = 22
  var tabHandle: UInt = 33
  func openSession(profileID: Data, sessionID: Data) throws -> UInt {
    calls.append("open-session")
    return sessionHandle
  }
  func closeSession(_ handle: UInt) throws { calls.append("close-session-\(handle)") }
  func openWindow(session: UInt, windowID: Data) throws -> UInt {
    calls.append("open-window")
    return windowHandle
  }
  func closeWindow(_ handle: UInt) throws { calls.append("close-window-\(handle)") }
  func openTab(session: UInt, window: UInt, tabID: Data, url: Data, foreground: Bool) throws -> UInt
  {
    calls.append("open-tab-\(foreground)")
    return tabHandle
  }
  func closeTab(_ handle: UInt) throws { calls.append("close-tab-\(handle)") }
  func activateTab(session: UInt, window: UInt, tab: UInt, requestID: UInt64) throws {
    calls.append("activate-\(requestID)")
  }
}

@Suite("Private sessions")
struct PrivateSessionsTests {
  @Test @MainActor func adapterCarriesScopeAndRejectsMismatches() throws {
    let engine = FakePrivateSessionsEngine()
    #expect(ShaarPrivateSessionsAdapter.makeIfSelected(engine: engine) != nil)
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

  @Test @MainActor func eventRoutingRequiresAllFourIDs() {
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

  @Test @MainActor func nullNativeHandlesAreRejectedBeforeTheyCanBeReused() throws {
    let sessionEngine = FakePrivateSessionsEngine()
    sessionEngine.sessionHandle = 0
    let sessionAdapter = ShaarPrivateSessionsAdapter(engine: sessionEngine)
    #expect(
      throws: ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private session open returned a null handle")
    ) {
      try sessionAdapter.openSession(
        profileID: Data("profile-a".utf8), sessionID: Data("session-a".utf8))
    }
    #expect(
      throws: ShaarEngineError.status(
        .notFound, platformCode: 0, message: "private session is closed")
    ) {
      try sessionAdapter.openWindow(sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8))
    }

    let windowEngine = FakePrivateSessionsEngine()
    let windowAdapter = ShaarPrivateSessionsAdapter(engine: windowEngine)
    _ = try windowAdapter.openSession(
      profileID: Data("profile-a".utf8), sessionID: Data("session-a".utf8))
    windowEngine.windowHandle = 0
    #expect(
      throws: ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private window open returned a null handle")
    ) {
      try windowAdapter.openWindow(
        sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8))
    }
    #expect(
      throws: ShaarEngineError.status(
        .wrongSession, platformCode: 0, message: "window is outside private session")
    ) {
      try windowAdapter.openTab(
        sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8),
        tabID: Data("tab-a".utf8), url: Data("about:blank".utf8), foreground: true)
    }

    let tabEngine = FakePrivateSessionsEngine()
    let tabAdapter = ShaarPrivateSessionsAdapter(engine: tabEngine)
    _ = try tabAdapter.openSession(
      profileID: Data("profile-a".utf8), sessionID: Data("session-a".utf8))
    _ = try tabAdapter.openWindow(sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8))
    tabEngine.tabHandle = 0
    #expect(
      throws: ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private tab open returned a null handle")
    ) {
      try tabAdapter.openTab(
        sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8),
        tabID: Data("tab-a".utf8), url: Data("about:blank".utf8), foreground: true)
    }
    #expect(
      throws: ShaarEngineError.status(
        .wrongSession, platformCode: 0, message: "tab is outside private window")
    ) {
      try tabAdapter.activateTab(
        sessionID: Data("session-a".utf8), windowID: Data("window-a".utf8),
        tabID: Data("tab-a".utf8), requestID: 1)
    }
  }

  @Test @MainActor func activationRejectsZeroRequestIDBeforeCallingEngine() throws {
    let engine = FakePrivateSessionsEngine()
    let adapter = ShaarPrivateSessionsAdapter(engine: engine)
    let profile = Data("profile-a".utf8)
    let session = Data("session-a".utf8)
    _ = try adapter.openSession(profileID: profile, sessionID: session)
    _ = try adapter.openWindow(sessionID: session, windowID: Data("window-a".utf8))
    try adapter.openTab(
      sessionID: session, windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      url: Data("about:blank".utf8), foreground: true)
    let callsBeforeActivation = engine.calls

    #expect(
      throws: ShaarEngineError.status(
        .invalidArgument, platformCode: 0, message: "private activation request ID must be nonzero")
    ) {
      try adapter.activateTab(
        sessionID: session, windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
        requestID: 0)
    }
    #expect(engine.calls == callsBeforeActivation)
  }

  @Test @MainActor func eventRoutingRejectsOwnerLevelKindsEvenWithMatchingObjectIDs() {
    let adapter = ShaarPrivateSessionsAdapter(engine: FakePrivateSessionsEngine())
    let event = ShaarCopiedEvent(
      sequence: 5, kind: 2, profileID: Data("p".utf8), sessionID: Data("s".utf8),
      windowID: Data("w".utf8), tabID: Data("t".utf8), payloadJSON: Data("{}".utf8))
    var delivered = false
    #expect(
      !adapter.routePrivateEvent(
        event, profileID: Data("p".utf8), sessionID: Data("s".utf8),
        windowID: Data("w".utf8), tabID: Data("t".utf8), handler: { _ in delivered = true }))
    #expect(!delivered)
  }

  @Test @MainActor func distinctSessionIDsCoexistPerProfile() throws {
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
