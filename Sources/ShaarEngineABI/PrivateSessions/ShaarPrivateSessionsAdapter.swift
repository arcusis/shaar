// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct ShaarPrivateSessionHandles: Equatable, Sendable {
  public let profileID: Data
  public let sessionID: Data
  public let session: UInt
  public init(profileID: Data, sessionID: Data, session: UInt) {
    self.profileID = profileID
    self.sessionID = sessionID
    self.session = session
  }
}

/// Narrow bridge used by the existing ARCChromiumRuntime facade. A production
/// implementation wraps the C ABI; tests inject a fake without loading Chromium.
@MainActor public protocol ShaarPrivateSessionsEngine: AnyObject {
  func openSession(profileID: Data, sessionID: Data) throws -> UInt
  func closeSession(_ handle: UInt) throws
  func openWindow(session: UInt, windowID: Data) throws -> UInt
  func closeWindow(_ handle: UInt) throws
  func openTab(session: UInt, window: UInt, tabID: Data, url: Data, foreground: Bool) throws -> UInt
  func closeTab(_ handle: UInt) throws
  func activateTab(session: UInt, window: UInt, tab: UInt, requestID: UInt64) throws
}

@MainActor public final class ShaarPrivateSessionsAdapter {
  private struct Key: Hashable {
    let profile: Data
    let session: Data
  }
  private let engine: any ShaarPrivateSessionsEngine
  private var sessions: [Key: ShaarPrivateSessionHandles] = [:]
  private var windows: [Data: (Key, UInt)] = [:]
  private var tabs: [Data: (Key, UInt, UInt)] = [:]

  public init(engine: any ShaarPrivateSessionsEngine) { self.engine = engine }

  /// The application uses the Shaar runtime; the existing
  /// implementation choice explicitly selects Shaar.
  public static func makeIfSelected(
    implementation: ShaarEngineImplementation = .shippingDefault,
    engine: any ShaarPrivateSessionsEngine
  ) -> ShaarPrivateSessionsAdapter? {
    guard implementation == .shaar else { return nil }
    return ShaarPrivateSessionsAdapter(engine: engine)
  }

  /// Private callbacks are routed only when every scope and object ID agrees
  /// with the live Swift owner. The C event bytes have already been copied.
  @discardableResult public func routePrivateEvent(
    _ event: ShaarCopiedEvent,
    profileID: Data,
    sessionID: Data,
    windowID: Data,
    tabID: Data,
    handler: (ShaarCopiedEvent) -> Void
  ) -> Bool {
    guard event.kind >= 4,
      !profileID.isEmpty, !sessionID.isEmpty, !windowID.isEmpty, !tabID.isEmpty,
      event.profileID == profileID, event.sessionID == sessionID,
      event.windowID == windowID, event.tabID == tabID
    else { return false }
    handler(event)
    return true
  }

  public func openSession(profileID: Data, sessionID: Data) throws -> ShaarPrivateSessionHandles {
    guard !profileID.isEmpty, !sessionID.isEmpty else {
      throw ShaarEngineError.status(
        .invalidArgument, platformCode: 0, message: "empty private scope")
    }
    let key = Key(profile: profileID, session: sessionID)
    if let existing = sessions[key] { return existing }
    guard !sessions.keys.contains(where: { $0.session == sessionID && $0.profile != profileID })
    else {
      throw ShaarEngineError.status(
        .wrongProfile, platformCode: 0, message: "session belongs to another profile")
    }
    let handle = try engine.openSession(profileID: profileID, sessionID: sessionID)
    guard handle != 0 else {
      throw ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private session open returned a null handle")
    }
    let result = ShaarPrivateSessionHandles(
      profileID: profileID, sessionID: sessionID, session: handle)
    sessions[key] = result
    return result
  }

  public func openWindow(sessionID: Data, windowID: Data) throws -> UInt {
    guard !windowID.isEmpty else {
      throw ShaarEngineError.status(
        .invalidArgument, platformCode: 0, message: "empty private window ID")
    }
    guard let entry = sessions.first(where: { $0.key.session == sessionID }) else {
      throw ShaarEngineError.status(
        .notFound, platformCode: 0, message: "private session is closed")
    }
    guard windows[windowID] == nil else {
      throw ShaarEngineError.status(
        .conflict, platformCode: 0, message: "window ID is already live")
    }
    let handle = try engine.openWindow(session: entry.value.session, windowID: windowID)
    guard handle != 0 else {
      throw ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private window open returned a null handle")
    }
    windows[windowID] = (entry.key, handle)
    return handle
  }

  public func openTab(sessionID: Data, windowID: Data, tabID: Data, url: Data, foreground: Bool)
    throws
  {
    guard !tabID.isEmpty, !url.isEmpty else {
      throw ShaarEngineError.status(
        .invalidArgument, platformCode: 0, message: "empty private tab ID or URL")
    }
    guard let entry = windows[windowID], entry.0.session == sessionID,
      let session = sessions[entry.0]
    else {
      throw ShaarEngineError.status(
        .wrongSession, platformCode: 0, message: "window is outside private session")
    }
    guard tabs[tabID] == nil else {
      throw ShaarEngineError.status(.conflict, platformCode: 0, message: "tab ID is already live")
    }
    let handle = try engine.openTab(
      session: session.session, window: entry.1, tabID: tabID, url: url, foreground: foreground)
    guard handle != 0 else {
      throw ShaarEngineError.status(
        .chromiumError, platformCode: 0, message: "private tab open returned a null handle")
    }
    tabs[tabID] = (entry.0, entry.1, handle)
  }

  public func closeTab(tabID: Data) throws {
    guard let entry = tabs[tabID] else {
      throw ShaarEngineError.status(.notFound, platformCode: 0, message: "private tab is closed")
    }
    try engine.closeTab(entry.2)
    tabs.removeValue(forKey: tabID)
  }

  public func closeWindow(windowID: Data) throws {
    guard let entry = windows[windowID] else {
      throw ShaarEngineError.status(.notFound, platformCode: 0, message: "private window is closed")
    }
    guard !tabs.values.contains(where: { $0.1 == entry.1 && $0.0 == entry.0 }) else {
      throw ShaarEngineError.status(
        .conflict, platformCode: 0, message: "private tabs must close first")
    }
    try engine.closeWindow(entry.1)
    windows.removeValue(forKey: windowID)
  }

  public func activateTab(sessionID: Data, windowID: Data, tabID: Data, requestID: UInt64) throws {
    guard requestID > 0 else {
      throw ShaarEngineError.status(
        .invalidArgument, platformCode: 0,
        message: "private activation request ID must be nonzero")
    }
    guard let window = windows[windowID], window.0.session == sessionID,
      let tab = tabs[tabID], tab.0 == window.0, tab.1 == window.1,
      let session = sessions[window.0]
    else {
      throw ShaarEngineError.status(
        .wrongSession, platformCode: 0, message: "tab is outside private window")
    }
    try engine.activateTab(
      session: session.session, window: window.1, tab: tab.2, requestID: requestID)
  }

  public func closeSession(profileID: Data, sessionID: Data) throws {
    let key = Key(profile: profileID, session: sessionID)
    guard let session = sessions[key] else { return }
    guard !windows.values.contains(where: { $0.0 == key }),
      !tabs.values.contains(where: { $0.0 == key })
    else {
      throw ShaarEngineError.status(
        .conflict, platformCode: 0, message: "private windows must close first")
    }
    try engine.closeSession(session.session)
    sessions.removeValue(forKey: key)
  }
}
