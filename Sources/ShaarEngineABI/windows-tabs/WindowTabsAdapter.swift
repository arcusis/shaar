// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The narrow window and tab surface used while callers migrate from ChromiumBridge.
/// Implementations must keep the underlying NSView borrowed and scoped to the window life.
@MainActor public protocol ShaarWindowTabsEngine: AnyObject {
  func openWindow(id: String, scope: ShaarTabScope) throws
  func bindProfile(id: String, windowID: String) throws
  func setActiveProfile(id: String, windowID: String) throws
  func closeWindow(id: String) throws
  func openTab(id: String, windowID: String, url: URL, foreground: Bool) throws
  func closeTab(id: String) throws
  func activateTab(id: String, windowID: String) throws
  func placeTabs(_ ids: [String], pinnedIDs: Set<String>, windowID: String) throws
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

/// State adapter for the Shaar implementation. Selection and placement validation happens
/// before calling the native engine so a rejected request never partially changes Swift state.
@MainActor public final class ShaarWindowTabsAdapter {
  private struct TabOwner {
    let windowID: String
    let profileID: String
  }

  public let implementation: ShaarEngineImplementation
  private let engine: ShaarWindowTabsEngine
  private var windows: [String: ShaarWindowTabsSnapshot] = [:]
  private var tabOwners: [String: TabOwner] = [:]

  public init(
    engine: ShaarWindowTabsEngine,
    implementation: ShaarEngineImplementation = .shaar
  ) {
    self.engine = engine
    self.implementation = implementation
  }

  public func openWindow(id: String, scope: ShaarTabScope) throws {
    guard !id.isEmpty, windows[id] == nil else { throw ShaarWindowTabsError.duplicateWindow }
    try engine.openWindow(id: id, scope: scope)
    windows[id] = .init(
      windowID: id, scope: scope, boundProfileIDs: [scope.profileID],
      activeProfileID: scope.profileID, orderedTabIDs: [], pinnedTabIDs: [], activeTabID: nil)
  }

  public func bindProfile(id: String, windowID: String) throws {
    guard let current = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    guard case .profile = current.scope, !id.isEmpty else {
      throw ShaarWindowTabsError.scopeMismatch
    }
    guard !current.boundProfileIDs.contains(id) else { return }
    try engine.bindProfile(id: id, windowID: windowID)
    windows[windowID] = .init(
      windowID: current.windowID, scope: current.scope,
      boundProfileIDs: current.boundProfileIDs.union([id]),
      activeProfileID: current.activeProfileID,
      orderedTabIDs: current.orderedTabIDs, pinnedTabIDs: current.pinnedTabIDs,
      activeTabID: current.activeTabID)
  }

  public func setActiveProfile(id: String, windowID: String) throws {
    guard let current = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    guard case .profile = current.scope, current.boundProfileIDs.contains(id) else {
      throw ShaarWindowTabsError.scopeMismatch
    }
    try engine.setActiveProfile(id: id, windowID: windowID)
    windows[windowID] = .init(
      windowID: current.windowID, scope: current.scope, boundProfileIDs: current.boundProfileIDs,
      activeProfileID: id, orderedTabIDs: current.orderedTabIDs,
      pinnedTabIDs: current.pinnedTabIDs, activeTabID: current.activeTabID)
  }

  public func closeWindow(id: String) throws {
    guard windows[id] != nil else { throw ShaarWindowTabsError.unknownWindow }
    try engine.closeWindow(id: id)
  }

  /// Apply only after Chromium confirms final closure on the ordered event stream.
  public func confirmWindowClosed(id: String) throws {
    guard let current = windows[id] else { throw ShaarWindowTabsError.unknownWindow }
    for tabID in current.orderedTabIDs {
      tabOwners.removeValue(forKey: tabID)
    }
    windows.removeValue(forKey: id)
  }

  public func openTab(
    id: String, windowID: String, scope: ShaarTabScope, url: URL, foreground: Bool
  ) throws {
    guard !id.isEmpty, tabOwners[id] == nil else { throw ShaarWindowTabsError.duplicateTab }
    guard let current = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    switch current.scope {
    case .profile:
      guard current.boundProfileIDs.contains(scope.profileID),
        case .profile = scope
      else { throw ShaarWindowTabsError.scopeMismatch }
    case .privateSession:
      guard current.scope == scope else { throw ShaarWindowTabsError.scopeMismatch }
    }
    try engine.openTab(id: id, windowID: windowID, url: url, foreground: foreground)
    let active = foreground ? id : current.activeTabID
    let activeProfile = foreground ? scope.profileID : current.activeProfileID
    windows[windowID] = .init(
      windowID: windowID, scope: current.scope, boundProfileIDs: current.boundProfileIDs,
      activeProfileID: activeProfile, orderedTabIDs: current.orderedTabIDs + [id],
      pinnedTabIDs: current.pinnedTabIDs, activeTabID: active)
    tabOwners[id] = TabOwner(windowID: windowID, profileID: scope.profileID)
  }

  public func closeTab(id: String) throws {
    guard tabOwners[id] != nil else { throw ShaarWindowTabsError.unknownTab }
    try engine.closeTab(id: id)
  }

  /// Apply only after the tab-strip observer reports the confirmed removal.
  public func confirmTabClosed(id: String) throws {
    guard let owner = tabOwners[id], let current = windows[owner.windowID],
      let index = current.orderedTabIDs.firstIndex(of: id)
    else { throw ShaarWindowTabsError.unknownTab }
    let remaining = current.orderedTabIDs.filter { $0 != id }
    let active =
      current.activeTabID == id
      ? (remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)])
      : current.activeTabID
    windows[owner.windowID] = .init(
      windowID: owner.windowID, scope: current.scope, boundProfileIDs: current.boundProfileIDs,
      activeProfileID: current.activeProfileID, orderedTabIDs: remaining,
      pinnedTabIDs: current.pinnedTabIDs.subtracting([id]), activeTabID: active)
    tabOwners.removeValue(forKey: id)
  }

  public func activateTab(id: String, windowID: String) throws {
    guard let owner = tabOwners[id], owner.windowID == windowID,
      let current = windows[windowID], current.boundProfileIDs.contains(owner.profileID)
    else {
      throw ShaarWindowTabsError.scopeMismatch
    }
    if current.activeProfileID != owner.profileID {
      try engine.setActiveProfile(id: owner.profileID, windowID: windowID)
    }
    try engine.activateTab(id: id, windowID: windowID)
    windows[windowID] = .init(
      windowID: windowID, scope: current.scope, boundProfileIDs: current.boundProfileIDs,
      activeProfileID: owner.profileID, orderedTabIDs: current.orderedTabIDs,
      pinnedTabIDs: current.pinnedTabIDs, activeTabID: id)
  }

  public func placeTabs(_ ids: [String], pinnedIDs: Set<String>, windowID: String) throws {
    guard let current = windows[windowID] else { throw ShaarWindowTabsError.unknownWindow }
    guard ids.count == Set(ids).count, Set(ids) == Set(current.orderedTabIDs),
      pinnedIDs.isSubset(of: Set(ids))
    else { throw ShaarWindowTabsError.invalidPlacement }
    let prefixCount = ids.prefix { pinnedIDs.contains($0) }.count
    guard ids.dropFirst(prefixCount).allSatisfy({ !pinnedIDs.contains($0) }) else {
      throw ShaarWindowTabsError.invalidPlacement
    }
    try engine.placeTabs(ids, pinnedIDs: pinnedIDs, windowID: windowID)
    windows[windowID] = .init(
      windowID: windowID, scope: current.scope, boundProfileIDs: current.boundProfileIDs,
      activeProfileID: current.activeProfileID, orderedTabIDs: ids,
      pinnedTabIDs: pinnedIDs, activeTabID: current.activeTabID)
  }

  public func snapshot(windowID: String) -> ShaarWindowTabsSnapshot? { windows[windowID] }

}

public enum ShaarWindowTabsError: Error, Equatable {
  case duplicateWindow, unknownWindow, duplicateTab, unknownTab, scopeMismatch, invalidPlacement
}
