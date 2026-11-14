// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@MainActor private final class FakeWindowTabsEngine: ShaarWindowTabsEngine {
  var calls: [String] = []
  var failingProfile: String?
  func openWindow(id: String, scope: ShaarTabScope) throws { calls.append("window+\(id)") }
  func borrowedWindowHostView(id: String) throws -> UnsafeMutableRawPointer? {
    calls.append("view-window:\(id)")
    return UnsafeMutableRawPointer(bitPattern: 0x1234)
  }
  func bindProfile(id: String, windowID: String) throws { calls.append("bind:\(id)") }
  func setActiveProfile(id: String, windowID: String) throws {
    calls.append("profile:\(id)")
    if id == failingProfile { throw ShaarEngineError.invalidEvent("profile activation failed") }
  }
  func closeWindow(id: String) throws { calls.append("window-\(id)") }
  func openTab(id: String, windowID: String, url: URL, foreground: Bool) throws {
    calls.append("tab+\(id):\(foreground)")
  }
  func borrowedTabHostView(id: String) throws -> UnsafeMutableRawPointer? {
    calls.append("view-tab:\(id)")
    return UnsafeMutableRawPointer(bitPattern: 0x5678)
  }
  func closeTab(id: String) throws { calls.append("tab-\(id)") }
  func activateTab(id: String, windowID: String) throws { calls.append("activate:\(id)") }
  func placeTabs(_ ids: [String], pinnedIDs: Set<String>, windowID: String) throws {
    calls.append("place:\(ids.joined(separator: ","))")
  }
  func resolveWindowRequest(requestID: UInt64, accepted: Bool, windowID: String?) throws {
    calls.append("resolve-window:\(requestID):\(accepted):\(windowID ?? "none")")
  }
  func resolveTabActivation(
    requestID: UInt64, accepted: Bool, windowID: String, tabID: String
  ) throws {
    calls.append("resolve-tab:\(requestID):\(accepted):\(windowID):\(tabID)")
  }
}

@MainActor private func makeShaarAdapter(
  _ engine: ShaarWindowTabsEngine
) -> ShaarWindowTabsAdapter {
  ShaarWindowTabsAdapter.makeIfSelected(engine: engine, implementation: .shaar)!
}

@Suite("Shaar windows and tabs adapter")
struct WindowTabsAdapterTests {
  @Test @MainActor func adapterIsAvailableOnShaarShippingDefault() {
    #expect(
      ShaarWindowTabsAdapter.makeIfSelected(engine: FakeWindowTabsEngine()) != nil)
  }

  @Test @MainActor func openingWindowRejectsEmptyScopeIdentifiers() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    #expect(throws: ShaarWindowTabsError.invalidScope) {
      try adapter.openWindow(id: "empty-profile", scope: .profile(""))
    }
    #expect(throws: ShaarWindowTabsError.invalidScope) {
      try adapter.openWindow(
        id: "empty-session", scope: .privateSession(profileID: "profile-a", sessionID: ""))
    }
    #expect(fake.calls.isEmpty)
  }

  @Test @MainActor func hostViewsRemainBorrowedAndRequireLiveHandles() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    try adapter.openWindow(id: "window-a", scope: .profile("profile-a"))
    #expect(
      try adapter.borrowedWindowHostView(id: "window-a")
        == UnsafeMutableRawPointer(bitPattern: 0x1234))
    #expect(throws: ShaarWindowTabsError.unknownTab) {
      try adapter.borrowedTabHostView(id: "missing")
    }
  }

  @Test @MainActor func foregroundAndBackgroundTabsKeepStableOrderAndSelection() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    let scope = ShaarTabScope.profile("profile-a")
    try adapter.openWindow(id: "window-a", scope: scope)
    try adapter.openTab(
      id: "tab-a", windowID: "window-a", scope: scope,
      url: URL(string: "https://a.example")!, foreground: true)
    try adapter.openTab(
      id: "tab-b", windowID: "window-a", scope: scope,
      url: URL(string: "https://b.example")!, foreground: false)
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == ["tab-a", "tab-b"])
    #expect(adapter.snapshot(windowID: "window-a")?.activeTabID == "tab-a")
    #expect(fake.calls.suffix(2) == ["tab+tab-a:true", "tab+tab-b:false"])
  }

  @Test @MainActor func placementRejectsDuplicatesAndNonPrefixPinnedIDsAtomically() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    let scope = ShaarTabScope.profile("profile-a")
    try adapter.openWindow(id: "window-a", scope: scope)
    for id in ["a", "b"] {
      try adapter.openTab(
        id: id, windowID: "window-a", scope: scope,
        url: URL(string: "https://\(id).example")!, foreground: id == "a")
    }
    #expect(throws: ShaarWindowTabsError.invalidPlacement) {
      try adapter.placeTabs(["b", "a"], pinnedIDs: ["a"], windowID: "window-a")
    }
    #expect(throws: ShaarWindowTabsError.invalidPlacement) {
      try adapter.placeTabs(["a", "a"], pinnedIDs: [], windowID: "window-a")
    }
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == ["a", "b"])
    #expect(fake.calls.last == "tab+b:false")
  }

  @Test @MainActor func privateScopeAndTabOwnershipAreChecked() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    let privateScope = ShaarTabScope.privateSession(profileID: "profile-a", sessionID: "session-a")
    try adapter.openWindow(id: "private-window", scope: privateScope)
    #expect(throws: ShaarWindowTabsError.scopeMismatch) {
      try adapter.openTab(
        id: "tab-a", windowID: "private-window", scope: .profile("profile-a"),
        url: URL(string: "about:blank")!, foreground: true)
    }
    #expect(throws: ShaarWindowTabsError.scopeMismatch) {
      try adapter.openTab(
        id: "tab-b", windowID: "private-window",
        scope: .privateSession(profileID: "profile-a", sessionID: "session-b"),
        url: URL(string: "about:blank")!, foreground: true)
    }
    try adapter.openTab(
      id: "tab-a", windowID: "private-window", scope: privateScope,
      url: URL(string: "about:blank")!, foreground: true)
    #expect(throws: ShaarWindowTabsError.scopeMismatch) {
      try adapter.activateTab(id: "tab-a", windowID: "some-other-window")
    }
  }

  @Test @MainActor func closeRequestsKeepHandlesUntilChromiumConfirmsRemoval() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    let scope = ShaarTabScope.profile("profile-a")
    try adapter.openWindow(id: "window-a", scope: scope)
    try adapter.openTab(
      id: "a", windowID: "window-a", scope: scope,
      url: URL(string: "https://a.example")!, foreground: true)
    try adapter.openTab(
      id: "b", windowID: "window-a", scope: scope,
      url: URL(string: "https://b.example")!, foreground: false)
    try adapter.closeTab(id: "a")
    #expect(adapter.snapshot(windowID: "window-a")?.activeTabID == "a")
    try adapter.confirmTabClosed(id: "a")
    #expect(adapter.snapshot(windowID: "window-a")?.activeTabID == "b")
    try adapter.closeWindow(id: "window-a")
    #expect(adapter.snapshot(windowID: "window-a") != nil)
    try adapter.confirmWindowClosed(id: "window-a")
    #expect(adapter.snapshot(windowID: "window-a") == nil)
  }

  @Test @MainActor func regularWindowRequiresBindingBeforeProfileSwitchOrTabOpen() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    try adapter.openWindow(id: "window-a", scope: .profile("profile-a"))
    #expect(throws: ShaarWindowTabsError.scopeMismatch) {
      try adapter.setActiveProfile(id: "profile-b", windowID: "window-a")
    }
    try adapter.bindProfile(id: "profile-b", windowID: "window-a")
    try adapter.setActiveProfile(id: "profile-b", windowID: "window-a")
    try adapter.openTab(
      id: "tab-b", windowID: "window-a", scope: .profile("profile-b"),
      url: URL(string: "https://b.example")!, foreground: true)
    #expect(adapter.snapshot(windowID: "window-a")?.boundProfileIDs == ["profile-a", "profile-b"])
    #expect(adapter.snapshot(windowID: "window-a")?.activeProfileID == "profile-b")
    try adapter.setActiveProfile(id: "profile-a", windowID: "window-a")
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == [])
    try adapter.setActiveProfile(id: "profile-b", windowID: "window-a")
    #expect(adapter.snapshot(windowID: "window-a")?.activeTabID == "tab-b")
  }

  @Test @MainActor func backgroundTabOpensInItsBoundProfileAndRestoresActiveProfile() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    try adapter.openWindow(id: "window-a", scope: .profile("profile-a"))
    try adapter.bindProfile(id: "profile-b", windowID: "window-a")
    fake.calls.removeAll()

    try adapter.openTab(
      id: "tab-b", windowID: "window-a", scope: .profile("profile-b"),
      url: URL(string: "https://b.example")!, foreground: false)

    #expect(fake.calls == ["profile:profile-b", "tab+tab-b:false", "profile:profile-a"])
    #expect(adapter.snapshot(windowID: "window-a")?.activeProfileID == "profile-a")
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == [])
    try adapter.setActiveProfile(id: "profile-b", windowID: "window-a")
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == ["tab-b"])
  }

  @Test @MainActor func foregroundTabOpensAfterSelectingItsBoundProfile() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    try adapter.openWindow(id: "window-a", scope: .profile("profile-a"))
    try adapter.bindProfile(id: "profile-b", windowID: "window-a")
    fake.calls.removeAll()

    try adapter.openTab(
      id: "tab-b", windowID: "window-a", scope: .profile("profile-b"),
      url: URL(string: "https://b.example")!, foreground: true)

    #expect(fake.calls == ["profile:profile-b", "tab+tab-b:true"])
    #expect(adapter.snapshot(windowID: "window-a")?.activeProfileID == "profile-b")
    #expect(adapter.snapshot(windowID: "window-a")?.activeTabID == "tab-b")
  }

  @Test @MainActor func backgroundTabRemainsTrackedWhenProfileRestoreFails() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    try adapter.openWindow(id: "window-a", scope: .profile("profile-a"))
    try adapter.bindProfile(id: "profile-b", windowID: "window-a")
    fake.calls.removeAll()
    fake.failingProfile = "profile-a"

    #expect(throws: ShaarEngineError.invalidEvent("profile activation failed")) {
      try adapter.openTab(
        id: "tab-b", windowID: "window-a", scope: .profile("profile-b"),
        url: URL(string: "https://b.example")!, foreground: false)
    }

    #expect(fake.calls == ["profile:profile-b", "tab+tab-b:false", "profile:profile-a"])
    #expect(adapter.snapshot(windowID: "window-a")?.activeProfileID == "profile-b")
    #expect(adapter.snapshot(windowID: "window-a")?.orderedTabIDs == ["tab-b"])
  }

  @Test @MainActor func requestRepliesRequireLiveScopedTargets() throws {
    let fake = FakeWindowTabsEngine()
    let adapter = makeShaarAdapter(fake)
    let scope = ShaarTabScope.profile("profile-a")
    try adapter.openWindow(id: "window-a", scope: scope)
    try adapter.openTab(
      id: "tab-a", windowID: "window-a", scope: scope,
      url: URL(string: "https://a.example")!, foreground: true)

    try adapter.resolveWindowRequest(requestID: 10, accepted: true, windowID: "window-a")
    try adapter.resolveWindowRequest(requestID: 11, accepted: false, windowID: nil)
    try adapter.resolveTabActivation(
      requestID: 12, accepted: true, windowID: "window-a", tabID: "tab-a")
    #expect(
      fake.calls.suffix(3) == [
        "resolve-window:10:true:window-a", "resolve-window:11:false:none",
        "resolve-tab:12:true:window-a:tab-a",
      ])
    #expect(throws: ShaarWindowTabsError.invalidRequest) {
      try adapter.resolveWindowRequest(requestID: 0, accepted: false, windowID: nil)
    }
    #expect(throws: ShaarWindowTabsError.invalidRequest) {
      try adapter.resolveWindowRequest(requestID: 13, accepted: false, windowID: "window-a")
    }
    #expect(throws: ShaarWindowTabsError.scopeMismatch) {
      try adapter.resolveTabActivation(
        requestID: 14, accepted: false, windowID: "other-window", tabID: "tab-a")
    }
  }
}
