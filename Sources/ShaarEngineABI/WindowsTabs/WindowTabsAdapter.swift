// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Narrow window and tab surface used while callers migrate from ChromiumBridge.
/// The host view remains borrowed and scoped to the lifetime of its window handle.
@MainActor public protocol ShaarWindowTabsEngine: AnyObject {
  func openWindow(id: String, scope: ShaarTabScope) throws
  func borrowedWindowHostView(id: String) throws -> UnsafeMutableRawPointer?
  func bindProfile(id: String, windowID: String) throws
  func setActiveProfile(id: String, windowID: String) throws
  func closeWindow(id: String) throws
  func openTab(id: String, windowID: String, url: URL, foreground: Bool) throws
  func borrowedTabHostView(id: String) throws -> UnsafeMutableRawPointer?
  func closeTab(id: String) throws
  func activateTab(id: String, windowID: String) throws
  func placeTabs(_ ids: [String], pinnedIDs: Set<String>, windowID: String) throws
  func resolveWindowRequest(requestID: UInt64, accepted: Bool, windowID: String?) throws
  func resolveTabActivation(
    requestID: UInt64, accepted: Bool, windowID: String, tabID: String
  ) throws
}

public enum ShaarTabScope: Equatable, Sendable {
  case profile(String)
  case privateSession(profileID: String, sessionID: String)

  var profileID: String {
    switch self {
    case .profile(let id), .privateSession(let id, _): id
    }
  }
}

public struct ShaarWindowTabsSnapshot: Equatable, Sendable {
  public let windowID: String
  public let scope: ShaarTabScope
  public let boundProfileIDs: Set<String>
  public let activeProfileID: String
  public let orderedTabIDs: [String]
  public let pinnedTabIDs: Set<String>
  public let activeTabID: String?
}

@MainActor public final class ShaarWindowTabsAdapter {
  private struct TabOwner {
    let windowID: String
    let profileID: String
  }

  private struct WindowState {
    let scope: ShaarTabScope
    var boundProfileIDs: Set<String>
    var activeProfileID: String
    var tabIDsByProfile: [String: [String]]
    var pinnedIDsByProfile: [String: Set<String>]
    var activeTabByProfile: [String: String]
  }

  public let implementation: ShaarEngineImplementation
  private let engine: ShaarWindowTabsEngine
  private var windows: [String: WindowState] = [:]
  private var tabOwners: [String: TabOwner] = [:]

  /// The Shaar adapter is constructed only when the existing explicit choice selects Shaar.
  /// Constructs the Shaar windows and tabs adapter.
  public static func makeIfSelected(
    engine: ShaarWindowTabsEngine,
    implementation: ShaarEngineImplementation = .shippingDefault
  ) -> ShaarWindowTabsAdapter? {
    guard implementation == .shaar else { return nil }
    return ShaarWindowTabsAdapter(engine: engine, implementation: implementation)
  }

  private init(engine: ShaarWindowTabsEngine, implementation: ShaarEngineImplementation) {
    self.engine = engine
    self.implementation = implementation
  }

  public func openWindow(id: String, scope: ShaarTabScope) throws {
    guard !id.isEmpty, windows[id] == nil else { throw ShaarWindowTabsError.duplicateWindow }
    guard !scope.profileID.isEmpty else { throw ShaarWindowTabsError.invalidScope }
    if case .privateSession(_, let sessionID) = scope, sessionID.isEmpty {
      throw ShaarWindowTabsError.invalidScope
    }
    try engine.openWindow(id: id, scope: scope)
    windows[id] = WindowState(
      scope: scope, boundProfileIDs: [scope.profileID], activeProfileID: scope.profileID,
      tabIDsByProfile: [scope.profileID: []], pinnedIDsByProfile: [scope.profileID: []],
      activeTabByProfile: [:])
  }

  public func bindProfile(id: String, windowID: String) throws {
    guard var state = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    guard case .profile = state.scope, !id.isEmpty else {
      throw ShaarWindowTabsError.scopeMismatch
    }
    guard !state.boundProfileIDs.contains(id) else { return }
    try engine.bindProfile(id: id, windowID: windowID)
    state.boundProfileIDs.insert(id)
    state.tabIDsByProfile[id] = []
    state.pinnedIDsByProfile[id] = []
    windows[windowID] = state
  }

  public func setActiveProfile(id: String, windowID: String) throws {
    guard var state = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    guard case .profile = state.scope, state.boundProfileIDs.contains(id) else {
      throw ShaarWindowTabsError.scopeMismatch
    }
    try engine.setActiveProfile(id: id, windowID: windowID)
    state.activeProfileID = id
    windows[windowID] = state
  }

  public func closeWindow(id: String) throws {
    guard windows[id] != nil else { throw ShaarWindowTabsError.unknownWindow }
    try engine.closeWindow(id: id)
  }

  /// Returns Chromium's NSView without retaining or taking ownership of it.
  public func borrowedWindowHostView(id: String) throws -> UnsafeMutableRawPointer? {
    guard windows[id] != nil else { throw ShaarWindowTabsError.unknownWindow }
    return try engine.borrowedWindowHostView(id: id)
  }

  /// Apply only after Chromium confirms final closure on the ordered event stream.
  public func confirmWindowClosed(id: String) throws {
    guard windows.removeValue(forKey: id) != nil else {
      throw ShaarWindowTabsError.unknownWindow
    }
    let closedTabIDs = tabOwners.compactMap { tabID, owner in
      owner.windowID == id ? tabID : nil
    }
    for tabID in closedTabIDs {
      tabOwners.removeValue(forKey: tabID)
    }
  }

  public func openTab(
    id: String, windowID: String, scope: ShaarTabScope, url: URL, foreground: Bool
  ) throws {
    guard !id.isEmpty, tabOwners[id] == nil else { throw ShaarWindowTabsError.duplicateTab }
    guard var state = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    switch state.scope {
    case .profile:
      guard state.boundProfileIDs.contains(scope.profileID), case .profile = scope else {
        throw ShaarWindowTabsError.scopeMismatch
      }
    case .privateSession:
      guard state.scope == scope else { throw ShaarWindowTabsError.scopeMismatch }
    }
    let previousProfileID = state.activeProfileID
    let needsProfileSwitch = previousProfileID != scope.profileID
    if needsProfileSwitch {
      try engine.setActiveProfile(id: scope.profileID, windowID: windowID)
    }
    do {
      try engine.openTab(id: id, windowID: windowID, url: url, foreground: foreground)
    } catch {
      if needsProfileSwitch {
        do {
          try engine.setActiveProfile(id: previousProfileID, windowID: windowID)
        } catch {
          state.activeProfileID = scope.profileID
          windows[windowID] = state
        }
      }
      throw error
    }
    state.tabIDsByProfile[scope.profileID, default: []].append(id)
    if foreground {
      state.activeProfileID = scope.profileID
      state.activeTabByProfile[scope.profileID] = id
    }
    if needsProfileSwitch && !foreground {
      do {
        try engine.setActiveProfile(id: previousProfileID, windowID: windowID)
      } catch {
        state.activeProfileID = scope.profileID
        windows[windowID] = state
        tabOwners[id] = TabOwner(windowID: windowID, profileID: scope.profileID)
        throw error
      }
    }
    windows[windowID] = state
    tabOwners[id] = TabOwner(windowID: windowID, profileID: scope.profileID)
  }

  public func closeTab(id: String) throws {
    guard tabOwners[id] != nil else { throw ShaarWindowTabsError.unknownTab }
    try engine.closeTab(id: id)
  }

  /// Returns the active tab's NSView without retaining or taking ownership of it.
  public func borrowedTabHostView(id: String) throws -> UnsafeMutableRawPointer? {
    guard tabOwners[id] != nil else { throw ShaarWindowTabsError.unknownTab }
    return try engine.borrowedTabHostView(id: id)
  }

  /// Apply only after the tab-strip observer reports the confirmed removal.
  public func confirmTabClosed(id: String) throws {
    guard let owner = tabOwners[id], var state = windows[owner.windowID],
      let index = state.tabIDsByProfile[owner.profileID]?.firstIndex(of: id)
    else { throw ShaarWindowTabsError.unknownTab }
    var order = state.tabIDsByProfile[owner.profileID] ?? []
    order.remove(at: index)
    state.tabIDsByProfile[owner.profileID] = order
    state.pinnedIDsByProfile[owner.profileID]?.remove(id)
    if state.activeTabByProfile[owner.profileID] == id {
      if order.isEmpty {
        state.activeTabByProfile.removeValue(forKey: owner.profileID)
      } else {
        state.activeTabByProfile[owner.profileID] = order[min(index, order.count - 1)]
      }
    }
    windows[owner.windowID] = state
    tabOwners.removeValue(forKey: id)
  }

  public func activateTab(id: String, windowID: String) throws {
    guard let owner = tabOwners[id], owner.windowID == windowID,
      var state = windows[windowID], state.boundProfileIDs.contains(owner.profileID)
    else { throw ShaarWindowTabsError.scopeMismatch }
    if state.activeProfileID != owner.profileID {
      try engine.setActiveProfile(id: owner.profileID, windowID: windowID)
      state.activeProfileID = owner.profileID
      windows[windowID] = state
    }
    try engine.activateTab(id: id, windowID: windowID)
    state.activeTabByProfile[owner.profileID] = id
    windows[windowID] = state
  }

  public func placeTabs(_ ids: [String], pinnedIDs: Set<String>, windowID: String) throws {
    guard var state = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    let profileID = state.activeProfileID
    let currentIDs = state.tabIDsByProfile[profileID] ?? []
    guard ids.count == Set(ids).count, Set(ids) == Set(currentIDs),
      pinnedIDs.isSubset(of: Set(ids))
    else { throw ShaarWindowTabsError.invalidPlacement }
    let prefixCount = ids.prefix { pinnedIDs.contains($0) }.count
    guard ids.dropFirst(prefixCount).allSatisfy({ !pinnedIDs.contains($0) }) else {
      throw ShaarWindowTabsError.invalidPlacement
    }
    try engine.placeTabs(ids, pinnedIDs: pinnedIDs, windowID: windowID)
    state.tabIDsByProfile[profileID] = ids
    state.pinnedIDsByProfile[profileID] = pinnedIDs
    windows[windowID] = state
  }

  public func resolveWindowRequest(
    requestID: UInt64, accepted: Bool, windowID: String?
  ) throws {
    guard requestID > 0 else { throw ShaarWindowTabsError.invalidRequest }
    if accepted {
      guard let windowID, windows[windowID] != nil else {
        throw ShaarWindowTabsError.unknownWindow
      }
    } else if windowID != nil {
      throw ShaarWindowTabsError.invalidRequest
    }
    try engine.resolveWindowRequest(
      requestID: requestID, accepted: accepted, windowID: windowID)
  }

  public func resolveTabActivation(
    requestID: UInt64, accepted: Bool, windowID: String, tabID: String
  ) throws {
    guard requestID > 0 else { throw ShaarWindowTabsError.invalidRequest }
    guard let owner = tabOwners[tabID], owner.windowID == windowID,
      windows[windowID]?.boundProfileIDs.contains(owner.profileID) == true
    else { throw ShaarWindowTabsError.scopeMismatch }
    try engine.resolveTabActivation(
      requestID: requestID, accepted: accepted, windowID: windowID, tabID: tabID)
  }

  public func snapshot(windowID: String) -> ShaarWindowTabsSnapshot? {
    guard let state = windows[windowID] else { return nil }
    let profileID = state.activeProfileID
    return ShaarWindowTabsSnapshot(
      windowID: windowID, scope: state.scope, boundProfileIDs: state.boundProfileIDs,
      activeProfileID: profileID, orderedTabIDs: state.tabIDsByProfile[profileID] ?? [],
      pinnedTabIDs: state.pinnedIDsByProfile[profileID] ?? [],
      activeTabID: state.activeTabByProfile[profileID])
  }
}

public enum ShaarWindowTabsError: Error, Equatable {
  case duplicateWindow, unknownWindow, duplicateTab, unknownTab, scopeMismatch, invalidPlacement,
    invalidRequest, invalidScope
}
