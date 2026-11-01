// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Darwin
import SwiftUI

@testable import ArcusisBrowser

private struct HostProbeSelection: Codable, Equatable {
  let space: UUID
  let tab: UUID?

  init(_ session: BrowserSession) {
    space = session.selectedSpaceID
    tab = session.selectedSpace.selectedTabID
  }
}

private struct HostProbeIdentity: Codable {
  let first: UUID
  let second: UUID
  let firstTab: UUID
  let secondTab: UUID
  let ordinarilyClosed: [UUID]
  var staleTab: UUID? = nil
  var engineWindow: UUID? = nil
  var engineTab: UUID? = nil
  var restorationSelections: [UUID: HostProbeSelection]? = nil
  var authoredProfile: HostProbeProfile? = nil
  var renamedProfile: HostProbeProfile? = nil
}

private struct HostProbeProfile: Codable {
  let id: UUID
  let name: String
}

private struct HostViewportRect: Codable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  init(_ rect: NSRect) {
    x = Double(rect.origin.x)
    y = Double(rect.origin.y)
    width = Double(rect.width)
    height = Double(rect.height)
  }
}

private struct HostViewportSample: Codable {
  let stage: String
  let windowID: UUID
  let tabID: UUID
  let profileID: UUID
  let accountID: String
  let documentInstance: String
  let innerWidthCSSPixels: Double
  let innerHeightCSSPixels: Double
  let devicePixelRatio: Double
  let backingScaleFactor: Double
  let sidebarVisible: Bool
  let windowFramePoints: HostViewportRect
  let contentBoundsPoints: HostViewportRect
  let hostingBoundsPoints: HostViewportRect
  let visibleHostingBoundsPoints: HostViewportRect
  let containerFrameInHostingPoints: HostViewportRect
  let containerBoundsPoints: HostViewportRect
  let pageFramePoints: HostViewportRect
  let expectedPageWidthPoints: Double
  let containerWithinVisibleHosting: Bool
  let containerFitsExpectedPageWidth: Bool
  let pageMatchesContainer: Bool
  let cssMatchesNativePoints: Bool
  let tabOwnerMatchesWindow: Bool
}

private struct HostViewportProof: Codable {
  let schema: Int
  let phase: String
  let passed: Bool
  let failureCode: String?
  let cssUnits: String
  let nativeUnits: String
  let scaleNote: String
  let checks: [String: Bool]
  let samples: [HostViewportSample]
}

private struct HostViewportWindowState {
  let context: NativeBrowserContext
  let frame: NSRect
  let selectedSpaceID: UUID
  let selectedTabID: UUID?
  let sidebarIsVisible: Bool
  let findTabID: UUID?
  let findQuery: String?
}

/// Exercises the production host class without ordering windows onscreen or sending OS input.
@MainActor
final class NativeHostProbe {
  let primary: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private let lock: WorkspaceProcessLock
  private let file: WorkspaceFile
  private var host: NativeBrowserHost?
  private var focused: NSWindow?
  private var closures: [UUID: Bool] = [:]
  private var checks: [String] = []
  private var faviconProof: [String: Any]?
  private var expectedAfterQuit: BrowserWorkspace?

  init(primary: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) throws {
    self.primary = primary
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    let directory = root.appending(path: "host-workspace")
    lock = try WorkspaceProcessLock(directory: directory)
    file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    try await verifyParentLock()
    let bases = Array(store.session.spaces.prefix(2))
    if phase == "initial" {
      let spaces = bases.enumerated().map { index, base in
        BrowserSpace(
          profileID: base.profileID, name: "Host \(index == 0 ? "alpha" : "beta")",
          symbol: base.symbol,
          tint: base.tint, tabs: [BrowserTab(url: fixture.appending(path: "host-initial-\(index)"))]
        )
      }
      try SessionFile(url: file.legacySessionURL).save(
        BrowserSession(
          profiles: store.session.profiles.filter { bases.map(\.profileID).contains($0.id) },
          spaces: spaces, selectedSpaceID: spaces[0].id))
    }
    let legacy = try Data(contentsOf: file.legacySessionURL)
    let manager = try BrowserWorkspaceStore(file: file)
    let host = NativeBrowserHost(
      events: primary.events, workspace: manager, presentation: .hiddenProbe,
      usesPrimaryWindow: false,
      keyWindow: { [weak self] in self?.focused },
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1080)] })
    self.host = host
    host.onClosed = { [weak self] id, quitting in self?.closures[id] = quitting }
    try host.restore()
    let checkpoint = root.appending(path: "host-identities.json")
    var firstID: UUID
    var secondID: UUID
    var closedIDs: [UUID] = []
    var staleTabID: UUID?
    var authoredProfile: HostProbeProfile?
    var renamedProfile: HostProbeProfile?
    if phase == "initial" {
      firstID = manager.workspace.windows[0].id
      focus(firstID)
      let initial = host.contexts[firstID]!
      _ = try await document(initial.store.session.selectedSpace.selectedTabID!)
      try send(.newWindow)
      secondID = manager.workspace.windows.first { $0.id != firstID }!.id
      try expect(
        host.contexts[secondID]!.store.session.spaces.flatMap(\.tabs).isEmpty,
        "native New window menu creates a managed window without copying ordinary live pages")
      focus(secondID)
      let secondStore = host.contexts[secondID]!.store
      secondStore.perform(.open(fixture.appending(path: "host-second-temporary")))
      let temporary = secondStore.session.selectedSpace.selectedTabID!
      staleTabID = temporary
      _ = try await document(temporary)
      let temporaryProfileID = secondStore.session.selectedSpace.profileID
      let wrongProfileID = secondStore.session.profiles.first { $0.id != temporaryProfileID }!.id
      try await verifyNativeNavigation(
        tabID: temporary, store: secondStore, profileID: temporaryProfileID,
        wrongProfileID: wrongProfileID, windowID: secondID.uuidString,
        wrongWindowID: firstID.uuidString)
      try send(.closeTab)
      try await wait("host close-tab recovery") {
        host.contexts[secondID]?.store.session.closedTabs.contains { $0.id == temporary } == true
      }
      try expect(
        !primary.runtime.navigateTabID(
          temporary.uuidString, profileID: temporaryProfileID.uuidString,
          windowID: secondID.uuidString, url: fixture.absoluteString),
        "native navigation rejects a closed tab identity")
      try expect(
        !initial.store.session.closedTabs.contains { $0.id == temporary },
        "native menu closure records recovery only in its focused managed window")
      try send(.reopenClosed)
      let reopened = host.contexts[secondID]!.store.session.selectedSpace.selectedTabID!
      _ = try await document(reopened)
      try expect(reopened != temporary, "native Reopen menu restores a fresh owning tab identity")
      try send(.closeWindow)
      try await wait("ordinary host window closure") { host.contexts[secondID] == nil }
      try expect(
        manager.workspace.window(secondID) == nil && closures[secondID] == false,
        "ordinary native window close removes only its confirmed managed record")
      focus(firstID)
      try send(.closeWindow)
      try await wait("last managed host window closure") { host.contexts.isEmpty }
      try expect(
        manager.workspace.windows.isEmpty && !primary.runtime.isQuitting,
        "closing all managed host windows retains the catalog and leaves the test runtime available"
      )
      closedIDs = [firstID, secondID]
      focused = nil
      try send(.newWindow)
      firstID = manager.workspace.windows[0].id
      let first = host.contexts[firstID]!.store
      first.perform(.space(first.session.spaces[1].id))
      first.perform(.open(fixture.appending(path: "host-beta-final")))
      focus(firstID)
      try send(.newWindow)
      secondID = manager.workspace.windows.first { $0.id != firstID }!.id
      let second = host.contexts[secondID]!.store
      second.perform(.space(second.session.spaces[0].id))
      second.perform(.open(fixture.appending(path: "host-alpha-final")))
    } else {
      let saved = try JSONDecoder().decode(
        HostProbeIdentity.self, from: Data(contentsOf: checkpoint))
      authoredProfile = saved.authoredProfile
      renamedProfile = saved.renamedProfile
      firstID = saved.first
      secondID = saved.second
      closedIDs = saved.ordinarilyClosed
      staleTabID = saved.staleTab
      let expected = Set([firstID, secondID] + [saved.engineWindow].compactMap { $0 })
      try expect(
        Set(host.contexts.keys) == expected
          && closedIDs.allSatisfy { host.contexts[$0] == nil },
        "native host startup restores retained windows and excludes ordinarily closed windows")
      guard let selections = saved.restorationSelections else {
        throw HostProbeFailure("Final host-restoration checkpoint is missing.")
      }
      guard saved.engineWindow == nil || saved.engineTab != nil else {
        throw HostProbeFailure("Saved engine-created fixture tab is missing.")
      }
      try expect(
        Set(selections.keys) == expected
          && selections.allSatisfy { id, selection in
            host.contexts[id].map { HostProbeSelection($0.store.session) == selection } == true
          },
        "production host restoration preserves each window's saved Space and tab selection")
      for id in [firstID, secondID] {
        let geometry = manager.workspace.window(id)!.geometry!
        try expect(
          host.contexts[id]!.window.frame
            == NSRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height),
          "production host restores saved window geometry \(id)")
      }
      if let id = saved.engineWindow, let restored = host.contexts[id],
        let tab = saved.engineTab
      {
        try selectFixture(tab, in: restored)
        let account = try await document(tab)
        try expect(
          account["cookie"] as? String == "account=alpha"
            && restored.store.session.selectedSpace.profileID == bases[0].profileID,
          "production startup restores the engine-created normal window in its saved account")
        primary.runtime.closeWindowID(restored.nativeID)
        try await wait("restored engine window closure") { host.contexts[id] == nil }
        closedIDs.append(id)
      }
      focus(secondID)
      try send(.newWindow)
      let empty = host.contexts.keys.first { ![firstID, secondID].contains($0) }!
      focus(empty)
      try send(.closeTab)
      try await wait("empty host window closure") { host.contexts[empty] == nil }
      try expect(
        manager.workspace.window(empty) == nil,
        "Close tab becomes Close window for an empty native window")
      closedIDs.append(empty)
      try selectFixture(saved.firstTab, in: host.contexts[firstID]!)
      try selectFixture(saved.secondTab, in: host.contexts[secondID]!)
    }
    let first = host.contexts[firstID]!
    let second = host.contexts[secondID]!
    let firstTab = first.store.session.selectedSpace.selectedTabID!
    let secondTab = second.store.session.selectedSpace.selectedTabID!
    let beta = try await document(firstTab)
    let alpha = try await document(secondTab)
    try expect(
      beta["cookie"] as? String == "account=beta" && alpha["cookie"] as? String == "account=alpha",
      "native host presents separate beta and alpha account sessions simultaneously")
    guard let staleTabID else {
      throw HostProbeFailure("Closed native fixture tab identity missing.")
    }
    try await verifyNativeFavicon(
      tabID: secondTab, profileID: second.store.session.selectedSpace.profileID,
      windowID: second.nativeID, wrongWindowID: first.nativeID, staleTabID: staleTabID)
    focus(secondID)
    let requested = try await EngineRequestedWindowProbe(
      host: host, root: root, fixture: fixture, phase: phase
    ).run(alpha: second, beta: first)
    checks += requested.checks
    try await verifyViewportLayout(
      first: first, firstTab: firstTab, second: second, secondTab: secondTab)
    focus(firstID)
    try send(.search)
    try expect(
      first.store.commandIsOpen && !second.store.commandIsOpen,
      "native search menu targets the first focused window")
    first.store.dismissCommand()
    focus(secondID)
    try send(.newTab)
    try expect(
      second.store.commandIsOpen && !first.store.commandIsOpen,
      "native New tab menu follows focus without changing another window")
    second.store.dismissCommand()
    try send(.find)
    second.store.updatePageFindQuery("OrbitFindMarker")
    try await wait("focused host Find") { second.store.pageFind?.canMove == true }
    try expect(
      first.store.pageFind == nil && second.store.pageFind?.tabID == secondTab,
      "native Find menu retains its focused document/profile boundary")
    second.store.dismissPageFind()
    let foreign = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
      backing: .buffered, defer: false)
    focused = foreign
    host.perform(.search)
    try expect(
      !host.canPerform(.closeWindow) && !host.canPerform(.reload) && !first.store.commandIsOpen
        && !second.store.commandIsOpen,
      "foreign key windows cannot fall back to another account's commands")
    focus(secondID)
    second.store.spaceEditor = .edit(second.store.session.selectedSpaceID)
    try expect(
      !host.canPerform(.newTab) && !host.canPerform(.closeWindow)
        && !host.canPerform(.settings) && host.canPerform(.newWindow),
      "native menu validation respects the focused window's modal state")
    second.store.sheet = nil
    second.store.sheetDidDismiss()
    let newWindowItem = try menuItem(.newWindow)
    let closeWindowItem = try menuItem(.closeWindow)
    let settingsItem = try menuItem(.settings)
    try expect(
      newWindowItem.keyEquivalent == "n" && newWindowItem.keyEquivalentModifierMask == .command
        && closeWindowItem.keyEquivalentModifierMask == [.command, .shift]
        && settingsItem.keyEquivalent == ","
        && settingsItem.keyEquivalentModifierMask == .command,
      "native menus register exact Command-N, Shift-Command-W, and Command-Comma chords")
    guard let settings = host.settingsController else {
      throw HostProbeFailure("Native Settings controller is missing.")
    }
    let sessionsBeforeSettings = Dictionary(
      uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value.store.session) })
    let selectedSpacesBeforeSettings = Dictionary(
      uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value.store.session.selectedSpaceID) })
    let profileSpacesBeforeSettings = settings.profiles
    let activeProfileBeforeSettings = host.activeContext?.store.session.selectedSpace.profileID
    try send(.settings)
    guard let openedSettingsWindow = settings.window else {
      throw HostProbeFailure("Native Settings menu did not create its window.")
    }
    guard let settingsContent = openedSettingsWindow.contentView else {
      throw HostProbeFailure("Native Settings content is missing.")
    }
    try await capture(settingsContent, index: 4)
    let selectedProfile = activeProfileBeforeSettings.flatMap { id in
      settings.profiles.first { $0.id == id }
    }
    try expect(
      settings.selectedProfileID == activeProfileBeforeSettings,
      "native Settings initially selects exactly the focused browser profile")
    let expectedSpaceCount = selectedProfile.map { profile in
      Set(host.workspace.workspace.catalog.spaces.filter { $0.profileID == profile.id }.map(\.id))
        .count
    }
    if let selectedProfile {
      _ = settings.selectProfile(selectedProfile.id)
      _ = settings.selectSearchEngine("duckDuckGo", for: selectedProfile.id)
    }
    settings.close()
    try expect(
      settingsItem.keyEquivalent == "," && settingsItem.keyEquivalentModifierMask == .command
        && (selectedProfile == nil
          || profileSpacesBeforeSettings.first(where: { $0.id == selectedProfile?.id })?.spaceCount
            == expectedSpaceCount)
        && sessionsBeforeSettings.allSatisfy {
          host.contexts[$0.key]?.store.session == $0.value
            && selectedSpacesBeforeSettings[$0.key]
              == host.contexts[$0.key]?.store.session.selectedSpaceID
        }
        && host.contexts.values.allSatisfy { !$0.window.isVisible }
        && !openedSettingsWindow.isVisible,
      "hidden native Settings selection preserves every browser account and session identity")
    try send(.settings)
    try expect(
      settings.window === openedSettingsWindow,
      "native Settings menu reuses its hidden window")
    focused = openedSettingsWindow
    try expect(
      host.canPerform(.closeTab) && host.canPerform(.closeWindow)
        && !host.canPerform(.search) && !host.canPerform(.find)
        && !host.canPerform(.reload),
      "Settings owns both close shortcuts and disables page commands")
    try send(.closeTab)
    try expect(
      !openedSettingsWindow.isVisible
        && sessionsBeforeSettings.allSatisfy { host.contexts[$0.key]?.store.session == $0.value },
      "Command-W closes Settings without closing an underlying browser tab")
    try send(.settings)
    try send(.closeWindow)
    try expect(
      !openedSettingsWindow.isVisible
        && sessionsBeforeSettings.allSatisfy { host.contexts[$0.key]?.store.session == $0.value },
      "Shift-Command-W closes Settings without closing an underlying browser window")
    focus(secondID)
    settings.close()
    try expect(
      !openedSettingsWindow.isVisible
        && host.contexts.values.allSatisfy { !$0.window.isVisible },
      "hidden native Settings never orders browser or Settings windows onscreen")
    let profileSessions = Dictionary(
      uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value.store.session) })
    let nativeWindowIDs = Dictionary(
      uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value.nativeID) })
    let nativeWindows = Dictionary(
      uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value.window) })
    let tabOwners = Dictionary(
      uniqueKeysWithValues: profileSessions.flatMap { windowID, session in
        session.spaces.flatMap { space in space.tabs.map { ($0.id, (windowID, space.profileID)) } }
      })
    var liveDocuments: [UUID: [String: Any]] = [:]
    for context in host.contexts.values {
      for space in context.store.session.spaces {
        for tab in space.tabs where primary.runtime.view(forTabID: tab.id.uuidString) != nil {
          _ = try await document(tab.id)
          if phase == "initial" {
            let seeded: String? = await withCheckedContinuation { continuation in
              primary.runtime.evaluate(
                inTabID: tab.id.uuidString,
                script:
                  "(() => {localStorage.setItem('arcusisProfileMutation','\(space.profileID.uuidString)');sessionStorage.setItem('arcusisProfileMutation','\(tab.id.uuidString)');return true;})()"
              ) { continuation.resume(returning: $0) }
            }
            guard seeded == "true" else {
              throw HostProbeFailure("Profile mutation fixture storage setup failed.")
            }
          }
          liveDocuments[tab.id] = try await document(tab.id)
        }
      }
    }
    if phase == "initial" {
      guard let selectedProfile else {
        throw HostProbeFailure("No profile available for rename probe.")
      }
      guard !settings.profiles.contains(where: { $0.name == "Probe unused" }) else {
        throw HostProbeFailure("Initial host fixture already contains authored profile.")
      }
      guard let addedID = settings.createProfile(name: "Probe unused") else {
        throw HostProbeFailure("Settings could not create the unused profile.")
      }
      guard let added = settings.profiles.first(where: { $0.id == addedID }) else {
        throw HostProbeFailure("Settings did not expose created profile.")
      }
      guard added.spaceCount == 0,
        settings.renameProfile(selectedProfile.id, name: "Probe renamed")
      else { throw HostProbeFailure("Settings could not rename existing profile.") }
      authoredProfile = HostProbeProfile(id: added.id, name: added.name)
      renamedProfile = HostProbeProfile(id: selectedProfile.id, name: "Probe renamed")
      var documentChecks = [
        "multipleLiveDocuments": liveDocuments.count >= 2,
        "profileStorageSeeded": true, "tabStorageSeeded": true,
        "nativeTabOwnerPreserved": true, "documentInstancePreserved": true,
        "cookiePreserved": true, "localStoragePreserved": true, "sessionStoragePreserved": true,
      ]
      for (id, before) in liveDocuments {
        let after = try await document(id)
        let checks = [
          "profileStorageSeeded": before["local"] as? String == tabOwners[id]?.1.uuidString,
          "tabStorageSeeded": before["session"] as? String == id.uuidString,
          "nativeTabOwnerPreserved": primary.runtime.windowID(forTabID: id.uuidString)
            == tabOwners[id].flatMap { nativeWindowIDs[$0.0] },
          "documentInstancePreserved": before["instance"] as? String == after["instance"]
            as? String,
          "cookiePreserved": before["cookie"] as? String == after["cookie"] as? String,
          "localStoragePreserved": before["local"] as? String == after["local"] as? String,
          "sessionStoragePreserved": before["session"] as? String == after["session"] as? String,
        ]
        for (key, value) in checks { documentChecks[key] = documentChecks[key] == true && value }
      }
      try JSONSerialization.data(withJSONObject: documentChecks, options: [.sortedKeys])
        .write(
          to: root.appending(path: "\(phase)-profile-mutation-documents.json"), options: .atomic)
      let documentsPreserved = documentChecks.values.allSatisfy { $0 }
      try expect(
        host.contexts.allSatisfy { id, context in
          let before = profileSessions[id]!
          let after = context.store.session
          let afterOwners = Dictionary(
            uniqueKeysWithValues: after.spaces.flatMap { space in
              space.tabs.map { ($0.id, (id, space.profileID)) }
            })
          return before.selectedSpaceID == after.selectedSpaceID
            && before.spaces.map(\.id) == after.spaces.map(\.id)
            && before.spaces.flatMap(\.tabs).map(\.id) == after.spaces.flatMap(\.tabs).map(\.id)
            && tabOwners.filter { $0.value.0 == id }.allSatisfy {
              afterOwners[$0.key]?.0 == $0.value.0 && afterOwners[$0.key]?.1 == $0.value.1
            }
            && nativeWindowIDs[id] == context.nativeID
            && primary.runtime.window(forID: context.nativeID) === nativeWindows[id]
            && Set(after.profiles.map(\.id)).contains(added.id)
        } && documentsPreserved
          && settings.profiles.count == profileSpacesBeforeSettings.count + 1
          && settings.profiles.first(where: { $0.id == selectedProfile.id })?.name
            == "Probe renamed"
          && settings.profiles.first(where: { $0.id == added.id })?.name == "Probe unused",
        "native Settings profile creation and rename preserve live windows, tabs, and documents")
    } else {
      guard let authoredProfile,
        settings.profiles.filter({ $0.id == authoredProfile.id && $0.name == authoredProfile.name })
          .count == 1,
        let renamedProfile,
        settings.profiles.filter({ $0.id == renamedProfile.id && $0.name == renamedProfile.name })
          .count == 1
      else {
        throw HostProbeFailure(
          "Authored profile identity/name did not survive restart exactly once.")
      }
    }
    first.window.setFrame(NSRect(x: 80, y: 90, width: 1000, height: 720), display: false)
    second.window.setFrame(NSRect(x: 150, y: 130, width: 980, height: 700), display: false)
    host.flushGeometry()
    try manager.flushSaves()
    try expect(
      manager.workspace.focusedWindowID == secondID && (try file.load()) == manager.workspace,
      "owned focus notifications and geometry persist in the managed snapshot")
    try expect(
      try Data(contentsOf: file.legacySessionURL) == legacy,
      "production host path retains the original legacy session bytes")
    try expect(
      host.contexts.values.allSatisfy { !$0.window.isVisible },
      "production host fixture keeps every native window hidden")
    for (index, context) in [first, second].enumerated() {
      try await capture(context.hosting, index: index + 1)
    }
    if let created = host.contexts[requested.retained] {
      try await capture(created.hosting, index: 3)
    }
    try await captureEditor(second.store)
    try JSONEncoder().encode(
      HostProbeIdentity(
        first: firstID, second: secondID, firstTab: firstTab, secondTab: secondTab,
        ordinarilyClosed: closedIDs, staleTab: staleTabID, engineWindow: requested.retained,
        engineTab: host.contexts[requested.retained]?.store.session.selectedSpace.selectedTabID,
        authoredProfile: authoredProfile, renamedProfile: renamedProfile)
    ).write(to: checkpoint, options: .atomic)
    try expect(
      host.lastError == nil && manager.storageNotice == nil,
      "native host completes without startup, geometry, or persistence errors")
  }

  private func verifyViewportLayout(
    first: NativeBrowserContext, firstTab: UUID,
    second: NativeBrowserContext, secondTab: UUID
  ) async throws {
    let savedStates = [viewportState(first), viewportState(second)]
    let savedFocus = focused
    var samples: [HostViewportSample] = []
    var viewportChecks: [String: Bool] = [:]

    do {
      try recordViewportCheck(
        "windowsRemainHidden", !first.window.isVisible && !second.window.isVisible,
        "Viewport probe windows stay hidden.", checks: &viewportChecks)
      let firstOriginal = try await viewportSample(
        "first-original", context: first, tabID: firstTab)
      let secondOriginal = try await viewportSample(
        "second-original", context: second, tabID: secondTab)
      samples += [firstOriginal, secondOriginal]
      try recordViewportCheck(
        "firstAndSecondPagesHaveDifferentAccounts",
        firstOriginal.accountID != secondOriginal.accountID,
        "Two owning windows retain distinct authored fixture accounts.", checks: &viewportChecks)
      try recordViewportCheck(
        "initialPagesMatchNativePoints",
        firstOriginal.cssMatchesNativePoints && secondOriginal.cssMatchesNativePoints
          && firstOriginal.pageMatchesContainer && secondOriginal.pageMatchesContainer
          && firstOriginal.containerWithinVisibleHosting
          && secondOriginal.containerWithinVisibleHosting
          && firstOriginal.containerFitsExpectedPageWidth
          && secondOriginal.containerFitsExpectedPageWidth,
        "Initial CSS viewport dimensions match each owning native page in logical points.",
        checks: &viewportChecks)

      var normalFrame = first.window.frame
      normalFrame.size = NSSize(
        width: max(first.window.minSize.width + 240, 1000),
        height: max(first.window.minSize.height + 220, 760))
      first.window.setFrame(normalFrame, display: false)
      try await settleViewportLayout(first)
      let firstNormal = try await viewportSample("first-normal", context: first, tabID: firstTab)
      let secondAfterNormal = try await viewportSample(
        "second-after-first-normal", context: second, tabID: secondTab)
      samples += [firstNormal, secondAfterNormal]
      try recordViewportCheck(
        "normalResizeChangesFirstCssViewport",
        firstNormal.innerWidthCSSPixels > 0 && firstNormal.innerHeightCSSPixels > 0
          && firstNormal.cssMatchesNativePoints && firstNormal.pageMatchesContainer
          && firstNormal.containerWithinVisibleHosting
          && firstNormal.containerFitsExpectedPageWidth,
        "Normal window resize produces a measurable first-window viewport.",
        checks: &viewportChecks)
      try recordViewportCheck(
        "normalResizeLeavesSecondWindowStable",
        viewportSizeMatches(secondAfterNormal, secondOriginal),
        "Resizing first owning window leaves second window viewport unchanged.",
        checks: &viewportChecks)

      var minimumFrame = normalFrame
      minimumFrame.size = first.window.minSize
      first.window.setFrame(minimumFrame, display: false)
      try await settleViewportLayout(first)
      let firstMinimum = try await viewportSample(
        "first-minimum", context: first, tabID: firstTab)
      let secondAfterMinimum = try await viewportSample(
        "second-after-first-minimum", context: second, tabID: secondTab)
      samples += [firstMinimum, secondAfterMinimum]
      try recordViewportCheck(
        "minimumResizeChangesFirstCssViewport",
        firstMinimum.windowFramePoints.width <= Double(first.window.minSize.width + 1)
          && firstMinimum.windowFramePoints.height <= Double(first.window.minSize.height + 1)
          && firstMinimum.cssMatchesNativePoints && firstMinimum.pageMatchesContainer
          && firstNormal.innerWidthCSSPixels > firstMinimum.innerWidthCSSPixels + 100
          && firstNormal.innerHeightCSSPixels > firstMinimum.innerHeightCSSPixels + 100
          && firstMinimum.containerWithinVisibleHosting
          && firstMinimum.containerFitsExpectedPageWidth,
        "Minimum window resize updates first-window CSS and native viewport dimensions.",
        checks: &viewportChecks)
      try recordViewportCheck(
        "minimumResizeLeavesSecondWindowStable",
        viewportSizeMatches(secondAfterMinimum, secondOriginal),
        "Minimum resize leaves second owning window viewport unchanged.",
        checks: &viewportChecks)

      first.window.setFrame(normalFrame, display: false)
      try await settleViewportLayout(first)
      let firstNormalBeforeChrome = try await viewportSample(
        "first-normal-before-chrome", context: first, tabID: firstTab)
      samples.append(firstNormalBeforeChrome)
      first.store.sidebarIsVisible = false
      try await settleViewportLayout(first)
      let sidebarHidden = try await viewportSample(
        "sidebar-hidden", context: first, tabID: firstTab)
      samples.append(sidebarHidden)
      first.store.sidebarIsVisible = true
      try await settleViewportLayout(first)
      let sidebarShown = try await viewportSample(
        "sidebar-shown", context: first, tabID: firstTab)
      let secondAfterSidebar = try await viewportSample(
        "second-after-sidebar", context: second, tabID: secondTab)
      samples += [sidebarShown, secondAfterSidebar]
      try recordViewportCheck(
        "sidebarChangesOnlyFirstWindowWidth",
        sidebarHidden.innerWidthCSSPixels > sidebarShown.innerWidthCSSPixels + 80
          && sidebarHidden.cssMatchesNativePoints && sidebarShown.cssMatchesNativePoints
          && sidebarHidden.containerWithinVisibleHosting
          && sidebarShown.containerWithinVisibleHosting
          && sidebarHidden.containerFitsExpectedPageWidth
          && sidebarShown.containerFitsExpectedPageWidth
          && viewportSizeMatches(secondAfterSidebar, secondOriginal),
        "Sidebar visibility changes first-window viewport while preserving second window.",
        checks: &viewportChecks)

      first.store.dismissPageFind()
      first.store.showPageFind()
      first.store.updatePageFindQuery("OrbitFindMarker")
      try await wait("viewport probe Find result") { first.store.pageFind?.canMove == true }
      try await settleViewportLayout(first)
      let findOpen = try await viewportSample("find-open", context: first, tabID: firstTab)
      samples.append(findOpen)
      first.store.dismissPageFind()
      try await settleViewportLayout(first)
      let findClosed = try await viewportSample("find-closed", context: first, tabID: firstTab)
      let secondAfterFind = try await viewportSample(
        "second-after-find", context: second, tabID: secondTab)
      samples += [findClosed, secondAfterFind]
      try recordViewportCheck(
        "findChangesOnlyFirstWindowHeight",
        findClosed.innerHeightCSSPixels > findOpen.innerHeightCSSPixels + 20
          && findOpen.cssMatchesNativePoints && findClosed.cssMatchesNativePoints
          && findOpen.containerWithinVisibleHosting
          && findClosed.containerWithinVisibleHosting
          && findOpen.containerFitsExpectedPageWidth
          && findClosed.containerFitsExpectedPageWidth
          && viewportSizeMatches(secondAfterFind, secondOriginal),
        "Find visibility changes first-window viewport while preserving second window.",
        checks: &viewportChecks)

      let identitiesPreserved = samples.allSatisfy { sample in
        let baseline = sample.tabID == firstTab ? firstOriginal : secondOriginal
        return sample.profileID == baseline.profileID
          && sample.accountID == baseline.accountID
          && sample.documentInstance == baseline.documentInstance
          && sample.tabOwnerMatchesWindow
          && sample.pageMatchesContainer
          && sample.cssMatchesNativePoints
          && sample.containerWithinVisibleHosting
          && sample.containerFitsExpectedPageWidth
      }
      try recordViewportCheck(
        "accountDocumentAndNativeOwnershipPreserved", identitiesPreserved,
        "Every viewport sample retains authored account, document instance, tab owner, and page bounds.",
        checks: &viewportChecks)

      try await restoreViewportState(savedStates, focusedWindow: savedFocus)
      let stateRestored =
        viewportStateMatches(savedStates)
        && ((savedFocus == nil && focused == nil)
          || (savedFocus != nil && focused === savedFocus))
      try recordViewportCheck(
        "selectionGeometrySidebarAndFindRestored", stateRestored,
        "Original selection, window geometry, sidebar, Find, and focused host window restored.",
        checks: &viewportChecks)
      try writeViewportProof(passed: true, samples: samples, checks: viewportChecks)
    } catch {
      try? await restoreViewportState(savedStates, focusedWindow: savedFocus)
      try? writeViewportProof(
        passed: false, samples: samples, checks: viewportChecks)
      throw error
    }
  }

  private func viewportState(_ context: NativeBrowserContext) -> HostViewportWindowState {
    HostViewportWindowState(
      context: context, frame: context.window.frame,
      selectedSpaceID: context.store.session.selectedSpaceID,
      selectedTabID: context.store.session.selectedSpace.selectedTabID,
      sidebarIsVisible: context.store.sidebarIsVisible,
      findTabID: context.store.pageFind?.tabID,
      findQuery: context.store.pageFind?.query)
  }

  private func restoreViewportState(
    _ states: [HostViewportWindowState], focusedWindow: NSWindow?
  ) async throws {
    for state in states {
      let context = state.context
      guard host?.contexts[context.id] === context else {
        throw HostProbeFailure("Viewport probe lost an owning production window.")
      }
      context.window.setFrame(state.frame, display: false)
      if let selectedTabID = state.selectedTabID {
        try selectFixture(selectedTabID, in: context)
      } else if context.store.session.selectedSpaceID != state.selectedSpaceID {
        context.store.perform(.space(state.selectedSpaceID))
      }
      context.store.sidebarIsVisible = state.sidebarIsVisible
      context.store.dismissPageFind()
      if let findTabID = state.findTabID {
        try selectFixture(findTabID, in: context)
        context.store.showPageFind()
        if let query = state.findQuery, !query.isEmpty {
          context.store.updatePageFindQuery(query)
        }
      }
      try await settleViewportLayout(context)
    }
    if let focusedWindow,
      let state = states.first(where: { $0.context.window === focusedWindow })
    {
      focus(state.context.id)
    } else {
      focused = focusedWindow
      if let focusedWindow {
        NotificationCenter.default.post(
          name: NSWindow.didBecomeKeyNotification, object: focusedWindow)
      }
    }
    host?.flushGeometry()
  }

  private func viewportStateMatches(_ states: [HostViewportWindowState]) -> Bool {
    states.allSatisfy { state in
      let context = state.context
      return context.window.frame == state.frame
        && context.store.session.selectedSpaceID == state.selectedSpaceID
        && context.store.session.selectedSpace.selectedTabID == state.selectedTabID
        && context.store.sidebarIsVisible == state.sidebarIsVisible
        && context.store.pageFind?.tabID == state.findTabID
        && context.store.pageFind?.query == state.findQuery
    }
  }

  private func settleViewportLayout(_ context: NativeBrowserContext) async throws {
    for _ in 0..<4 {
      context.window.displayIfNeeded()
      context.contentView.layoutSubtreeIfNeeded()
      context.hosting.layoutSubtreeIfNeeded()
      await Task.yield()
      try await Task.sleep(for: .milliseconds(30))
    }
    context.window.displayIfNeeded()
    context.contentView.layoutSubtreeIfNeeded()
    context.hosting.layoutSubtreeIfNeeded()
  }

  private func captureNativeHitTesting(_ stage: String, context: NativeBrowserContext) throws {
    guard let frame = context.window.contentView?.superview else {
      throw HostProbeFailure("Native window frame view is missing.")
    }
    let drag = context.titlebarDragView
    // The sidebar toggle sits right of the traffic lights; blank titlebar starts after it.
    let zoom = context.window.standardWindowButton(.zoomButton)
    let accessoriesEnd =
      (zoom.map { $0.convert($0.bounds, to: frame).maxX } ?? 70) + 8
      + BrowserChromeLayout.titlebarAccessoryWidth
    let points = [accessoriesEnd + 12, frame.bounds.midX, frame.bounds.maxX - 20].map {
      NSPoint(x: $0, y: frame.isFlipped ? 16 : frame.bounds.maxY - 16)
    }
    let hits: [[String: Any]] = points.map { point in
      let hit = frame.hitTest(point)
      return [
        "x": point.x, "y": point.y,
        "class": hit.map { String(describing: type(of: $0)) } ?? "none",
        "isDragView": hit === drag,
        "isHostedUI": hit.map { $0 === context.hosting || $0.isDescendant(of: context.hosting) }
          ?? false,
      ]
    }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { context.window.standardWindowButton($0) }
    let trafficLightsRemainInteractive =
      buttons.count == 3
      && buttons.allSatisfy { button in
        let center = button.convert(
          NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frame)
        let hit = frame.hitTest(center)
        return hit === button || hit?.isDescendant(of: button) == true
      }
    let pagePoint = context.hosting.convert(
      NSPoint(x: context.hosting.bounds.midX, y: context.hosting.bounds.midY), to: frame)
    let pageHit = frame.hitTest(pagePoint)
    let pageRemainsInteractive = pageHit != nil && pageHit !== drag
    let blankTopEdgeRoutesToDrag =
      !drag.isHidden
      && hits.allSatisfy {
        $0["isDragView"] as? Bool == true
      }
    func describe(_ view: NSView, depth: Int) -> [String: Any] {
      [
        "class": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame),
        "bounds": NSStringFromRect(view.bounds), "hidden": view.isHidden,
        "flipped": view.isFlipped,
        "children": depth < 3
          ? view.subviews.prefix(16).map { describe($0, depth: depth + 1) } : [],
      ]
    }
    try JSONSerialization.data(
      withJSONObject: [
        "stage": stage, "windowID": context.id.uuidString,
        "layout": NSStringFromRect(context.window.contentLayoutRect),
        "dragFrame": NSStringFromRect(drag.frame), "dragHidden": drag.isHidden,
        "dragInWindowFrame": drag.superview === frame,
        "firstResponderClass": context.window.firstResponder.map {
          String(describing: type(of: $0))
        } ?? "none",
        "topHits": hits, "hierarchy": describe(frame, depth: 0),
        "blankTopEdgeRoutesToDrag": blankTopEdgeRoutesToDrag,
        "trafficLightsRemainInteractive": trafficLightsRemainInteractive,
        "pageRemainsInteractive": pageRemainsInteractive,
        "scope": "Hidden native frame hit testing; no physical input or drag movement proof.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-hit-test-\(stage).json"), options: .atomic)
    try expect(
      blankTopEdgeRoutesToDrag && trafficLightsRemainInteractive && pageRemainsInteractive,
      "Native frame routes blank top edge to drag view while preserving traffic lights and page: \(stage)"
    )
  }

  private func viewportSample(
    _ stage: String, context: NativeBrowserContext, tabID: UUID
  ) async throws -> HostViewportSample {
    try await settleViewportLayout(context)
    try captureNativeHitTesting(stage, context: context)
    let document = try await document(tabID)
    guard document["fixture"] as? String == "v1",
      let instance = document["instance"] as? String,
      let cookie = document["cookie"] as? String,
      let accountID = cookie.split(separator: ";").compactMap({ item -> String? in
        let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        return pair.count == 2 && pair[0] == "account" ? String(pair[1]) : nil
      }).first,
      let cssWidth = (document["innerWidth"] as? NSNumber)?.doubleValue,
      let cssHeight = (document["innerHeight"] as? NSNumber)?.doubleValue,
      let devicePixelRatio = (document["devicePixelRatio"] as? NSNumber)?.doubleValue,
      let page = primary.runtime.view(forTabID: tabID.uuidString),
      let container = pageContainer(in: context.hosting, page: page),
      page.superview === container
    else { throw HostProbeFailure("Authored viewport fixture or native page view is missing.") }
    let containerBounds = container.bounds
    let pageFrame = page.frame
    let containerFrame = container.convert(containerBounds, to: context.hosting)
    let visibleHostingBounds = context.hosting.convert(context.window.contentLayoutRect, from: nil)
    let inset = BrowserChromeLayout.pageCardInset
    let sidebar = context.store.sidebarIsVisible ? BrowserChromeLayout.sidebarWidth : 0
    let expectedMinX = visibleHostingBounds.minX + sidebar + inset
    let expectedMaxX = visibleHostingBounds.maxX - inset
    let expectedWidth = max(0, expectedMaxX - expectedMinX)
    let tolerance: CGFloat = 1
    let containerWithinVisibleHosting =
      containerFrame.minX >= visibleHostingBounds.minX - tolerance
      && containerFrame.maxX <= visibleHostingBounds.maxX + tolerance
      && containerFrame.minY >= visibleHostingBounds.minY - tolerance
      && containerFrame.maxY <= visibleHostingBounds.maxY + tolerance
    let containerFitsExpectedPageWidth =
      abs(containerFrame.width - expectedWidth) <= tolerance
      && containerFrame.minX >= expectedMinX - tolerance
      && containerFrame.maxX <= expectedMaxX + tolerance
    let pageMatchesContainer = pageFrame == containerBounds
    let cssMatchesNativePoints =
      abs(cssWidth - Double(pageFrame.width)) <= 1
      && abs(cssHeight - Double(pageFrame.height)) <= 1
    return HostViewportSample(
      stage: stage, windowID: context.id, tabID: tabID,
      profileID: context.store.session.selectedSpace.profileID,
      accountID: accountID, documentInstance: instance,
      innerWidthCSSPixels: cssWidth, innerHeightCSSPixels: cssHeight,
      devicePixelRatio: devicePixelRatio,
      backingScaleFactor: Double(context.window.backingScaleFactor),
      sidebarVisible: context.store.sidebarIsVisible,
      windowFramePoints: HostViewportRect(context.window.frame),
      contentBoundsPoints: HostViewportRect(context.contentView.bounds),
      hostingBoundsPoints: HostViewportRect(context.hosting.bounds),
      visibleHostingBoundsPoints: HostViewportRect(visibleHostingBounds),
      containerFrameInHostingPoints: HostViewportRect(containerFrame),
      containerBoundsPoints: HostViewportRect(containerBounds),
      pageFramePoints: HostViewportRect(pageFrame),
      expectedPageWidthPoints: Double(expectedWidth),
      containerWithinVisibleHosting: containerWithinVisibleHosting,
      containerFitsExpectedPageWidth: containerFitsExpectedPageWidth,
      pageMatchesContainer: pageMatchesContainer,
      cssMatchesNativePoints: cssMatchesNativePoints,
      tabOwnerMatchesWindow: primary.runtime.windowID(forTabID: tabID.uuidString)
        == context.nativeID)
  }

  private func pageContainer(in view: NSView, page: NSView) -> ChromiumPageContainerView? {
    if let container = view as? ChromiumPageContainerView, container.pageView === page {
      return container
    }
    for child in view.subviews {
      if let found = pageContainer(in: child, page: page) { return found }
    }
    return nil
  }

  private func viewportSizeMatches(_ lhs: HostViewportSample, _ rhs: HostViewportSample) -> Bool {
    abs(lhs.innerWidthCSSPixels - rhs.innerWidthCSSPixels) <= 1
      && abs(lhs.innerHeightCSSPixels - rhs.innerHeightCSSPixels) <= 1
  }

  private func recordViewportCheck(
    _ key: String, _ passed: Bool, _ message: String, checks: inout [String: Bool]
  ) throws {
    checks[key] = passed
    try expect(passed, message)
  }

  private func writeViewportProof(
    passed: Bool, samples: [HostViewportSample], checks: [String: Bool]
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let proof = HostViewportProof(
      schema: 1, phase: phase, passed: passed,
      failureCode: passed ? nil : "viewport_acceptance_failed",
      cssUnits: "CSS pixels from window.innerWidth and window.innerHeight",
      nativeUnits: "logical AppKit points from NSView and NSWindow bounds",
      scaleNote:
        "devicePixelRatio and backingScaleFactor recorded separately; no DPR multiplication",
      checks: checks, samples: samples)
    let data = try encoder.encode(proof)
    guard data.count <= 64 * 1024 else {
      throw HostProbeFailure("Viewport proof exceeded its bounded fixture report size.")
    }
    try data.write(to: root.appending(path: "\(phase)-native-viewport.json"), options: .atomic)
  }

  func prepareForQuit() throws {
    guard let host else { return }
    host.flushGeometry()
    guard host.workspace.persistSnapshot() else {
      throw HostProbeFailure("Host quit snapshot failed.")
    }
    expectedAfterQuit = host.workspace.workspace
    if phase == "initial" {
      let checkpoint = root.appending(path: "host-identities.json")
      var saved = try JSONDecoder().decode(
        HostProbeIdentity.self, from: Data(contentsOf: checkpoint))
      saved.restorationSelections = Dictionary(
        uniqueKeysWithValues: host.workspace.workspace.windows.map {
          ($0.id, HostProbeSelection($0.session))
        })
      try JSONEncoder().encode(saved).write(to: checkpoint, options: .atomic)
    }
  }

  func auditAfterQuit() throws -> [String] {
    guard let host, let expectedAfterQuit else { return [] }
    for _ in 0..<10 where !host.contexts.isEmpty {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    do {
      guard host.contexts.isEmpty, expectedAfterQuit.windows.allSatisfy({ closures[$0.id] == true })
      else {
        throw HostProbeFailure(
          "Actual engine quit did not deliver all host window closures as quitting.")
      }
      guard try file.load() == expectedAfterQuit else {
        throw HostProbeFailure("Actual engine quit changed retained window models.")
      }
      try report(error: nil)
      host.detach()
      return [
        "actual engine quit delivers owned host closures without ordinary-window deletion",
        "retained native host models and geometry remain intact after the engine loop exits",
      ]
    } catch {
      try? report(error: error)
      host.detach()
      throw error
    }
  }

  private func focus(_ id: UUID) {
    focused = host?.contexts[id]?.window
    if let focused {
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: focused)
    }
  }

  private func selectFixture(_ tab: UUID, in context: NativeBrowserContext) throws {
    guard
      let space = context.store.session.spaces.first(where: {
        $0.tabs.contains(where: { $0.id == tab })
      })
    else { throw HostProbeFailure("Saved host fixture tab is missing.") }
    context.store.perform(.tab(space: space.id, tab: tab))
  }

  private func menuItem(_ command: BrowserMenuCommand) throws -> NSMenuItem {
    guard
      let item = host?.menu?.items.flatMap({ $0.submenu?.items ?? [] }).first(where: {
        $0.representedObject as? String == command.rawValue
      })
    else { throw HostProbeFailure("Missing native menu \(command).") }
    return item
  }

  private func send(_ command: BrowserMenuCommand) throws {
    guard let host, host.canPerform(command) else {
      throw HostProbeFailure("Native menu disabled: \(command).")
    }
    let item = try menuItem(command)
    guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
      throw HostProbeFailure("Native menu action failed: \(command).")
    }
  }

  private func verifyParentLock() async throws {
    let token = UUID().uuidString
    try JSONSerialization.data(withJSONObject: [
      "schema": 1, "pid": getpid(), "phase": phase, "token": token,
      "lockFile": "host-workspace/workspace.lock",
    ]).write(to: root.appending(path: "\(phase)-host-lock-ready.json"), options: .atomic)
    let receipt = root.appending(path: "\(phase)-host-lock-receipt.json")
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: receipt.path) {
        let value =
          try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
        try expect(
          value?["blocked"] as? Bool == true && value?["pid"] as? Int32 == getpid()
            && value?["parentPID"] as? Int32 == getppid() && value?["token"] as? String == token
            && value?["phase"] as? String == phase,
          "another process cannot acquire the active native workspace writer lock")
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Parent workspace-lock verification did not arrive.")
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      let json: String? = await withCheckedContinuation { continuation in
        primary.runtime.evaluate(
          inTabID: id.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('arcusisProfileMutation'),session:sessionStorage.getItem('arcusisProfileMutation'),innerWidth:window.innerWidth,innerHeight:window.innerHeight,devicePixelRatio:window.devicePixelRatio})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1", value["instance"] as? String != nil
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Native host fixture document not ready.")
  }

  private func verifyNativeNavigation(
    tabID: UUID, store: BrowserStore, profileID: UUID, wrongProfileID: UUID,
    windowID: String, wrongWindowID: String
  ) async throws {
    let runtime = primary.runtime
    let tabIdentity = tabID.uuidString
    let profileIdentity = profileID.uuidString
    let nativeTabID = runtime.nativeTabID(forID: tabIdentity)
    let destination = fixture.appending(path: "host-second-navigation-target")
    try expect(
      runtime.navigateTabID(
        tabIdentity, profileID: profileIdentity, windowID: windowID,
        url: destination.absoluteString),
      "native navigation accepts an owned HTTP URL")

    let rejectedOwners =
      !runtime.navigateTabID(
        tabIdentity, profileID: wrongProfileID.uuidString, windowID: windowID,
        url: destination.absoluteString)
      && !runtime.navigateTabID(
        tabIdentity, profileID: profileIdentity, windowID: wrongWindowID,
        url: destination.absoluteString)
    let rejectedURLs = [
      "javascript:location.href='about:blank'", "file:///etc/passwd", "mailto:test@example.invalid",
      "chrome://version", "about:blank#other", "https://", "http://127.0.0.1:99999/", "",
    ].allSatisfy {
      !runtime.navigateTabID(
        tabIdentity, profileID: profileIdentity, windowID: windowID, url: $0)
    }
    try expect(rejectedOwners, "native navigation rejects wrong profile and window owners")
    try expect(rejectedURLs, "native navigation rejects unsupported and invalid URLs")
    try await waitForLocation(destination.absoluteString, tabID: tabID)
    _ = try await document(tabID)

    let acceptedBlank = runtime.navigateTabID(
      tabIdentity, profileID: profileIdentity, windowID: windowID, url: "about:blank")
    try expect(acceptedBlank, "native navigation accepts exact about:blank")
    try await waitForLocation("about:blank", tabID: tabID)
    let restoredFixture = runtime.navigateTabID(
      tabIdentity, profileID: profileIdentity, windowID: windowID,
      url: destination.absoluteString)
    try expect(restoredFixture, "native navigation accepts fixture URL after about:blank")
    try await waitForLocation(destination.absoluteString, tabID: tabID)
    _ = try await document(tabID)
    try expect(
      runtime.nativeTabID(forID: tabIdentity) == nativeTabID
        && runtime.windowID(forTabID: tabIdentity) == windowID
        && store.session.selectedSpace.selectedTabID == tabID
        && store.session.selectedSpace.profileID == profileID,
      "native navigation preserves tab, profile, and window identity")
  }

  private func waitForLocation(_ expected: String, tabID: UUID) async throws {
    for _ in 0..<100 {
      let json: String? = await withCheckedContinuation { continuation in
        primary.runtime.evaluate(inTabID: tabID.uuidString, script: "({href:location.href})") {
          continuation.resume(returning: $0)
        }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        value["href"] == expected
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Native navigation did not commit the expected fixture URL.")
  }

  private func verifyNativeFavicon(
    tabID: UUID, profileID: UUID, windowID: String, wrongWindowID: String, staleTabID: UUID
  ) async throws {
    let runtime = primary.runtime
    let wrongProfileID = store.session.profiles.first { $0.id != profileID }!.id
    let previous = runtime.onTabChanged
    var targetChanges = 0
    runtime.onTabChanged = { id, url, title, loading, canGoBack, canGoForward in
      if id == tabID.uuidString { targetChanges += 1 }
      previous?(id, url, title, loading, canGoBack, canGoForward)
    }
    defer { runtime.onTabChanged = previous }

    let expectedBytes = phase == "initial" ? [52.0, 86.0, 120.0] : [138.0, 75.0, 18.0]
    let expectedRGB = expectedBytes.map { $0 / 255 }
    let expected = NSColor(
      deviceRed: expectedRGB[0], green: expectedRGB[1], blue: expectedRGB[2], alpha: 1)
    var faviconComponents = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    faviconComponents.path = "/favicon-\(phase).png"
    faviconComponents.query = nil
    faviconComponents.fragment = nil
    let faviconURL = faviconComponents.url!.absoluteString
    let script =
      "(()=>{const link=document.createElement('link');link.rel='icon';"
      + "link.href='\(faviconURL)';document.head.append(link);return true})()"
    func bitmapRepresentation(_ image: NSImage?) -> NSBitmapImageRep? {
      image?.representations.compactMap { $0 as? NSBitmapImageRep }.first
    }
    func matchesAuthoredIcon(_ image: NSImage?) -> Bool {
      guard let bitmap = bitmapRepresentation(image),
        bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
        let sample = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
      else { return false }
      return abs(sample.redComponent - expected.redComponent) < 0.07
        && abs(sample.greenComponent - expected.greenComponent) < 0.07
        && abs(sample.blueComponent - expected.blueComponent) < 0.07
    }
    let injected: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tabID.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    try expect(injected != nil, "owned fixture accepts authored loopback PNG favicon link")
    let routedClient = primary.events.router.client(
      forTab: tabID.uuidString, nativeWindowID: windowID)
    try expect(
      runtime.favicon(
        forTabID: tabID.uuidString, profileID: wrongProfileID.uuidString, windowID: windowID) == nil
        && runtime.favicon(
          forTabID: tabID.uuidString, profileID: profileID.uuidString,
          windowID: wrongWindowID) == nil
        && runtime.favicon(
          forTabID: staleTabID.uuidString, profileID: profileID.uuidString,
          windowID: windowID) == nil,
      "native favicon getter rejects wrong profile, wrong window, and closed tab identities")
    try expect(
      routedClient?.windowID == windowID
        && primary.events.router.client(forTab: tabID.uuidString, nativeWindowID: wrongWindowID)
          == nil,
      "native tab callback route resolves only its owning window client")

    var image: NSImage?
    for _ in 0..<100 {
      image = runtime.favicon(
        forTabID: tabID.uuidString, profileID: profileID.uuidString, windowID: windowID)
      if matchesAuthoredIcon(image) && targetChanges > 0 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let size = image?.size ?? .zero
    let bitmap = bitmapRepresentation(image)
    let center = bitmap.flatMap {
      $0.colorAt(x: $0.pixelsWide / 2, y: $0.pixelsHigh / 2)
    }
    let centerRGB = center.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
    let ownerRoute =
      routedClient?.windowID == windowID
      && primary.events.router.client(
        forTab: tabID.uuidString, nativeWindowID: wrongWindowID) == nil
    faviconProof = [
      "phase": phase,
      "route": faviconURL,
      "getterNil": image == nil,
      "imageWidth": bitmap?.pixelsWide ?? 0,
      "imageHeight": bitmap?.pixelsHigh ?? 0,
      "centerRGB": centerRGB as Any? ?? NSNull(),
      "expectedRGB": expectedRGB,
      "centerMatchesExpected": matchesAuthoredIcon(image),
      "targetTabChangeCount": targetChanges,
      "ownerRouteMatches": ownerRoute,
      "wrongOwnerRouteNil": primary.events.router.client(
        forTab: tabID.uuidString, nativeWindowID: wrongWindowID) == nil,
    ]
    let faviconData = try JSONSerialization.data(
      withJSONObject: faviconProof!, options: [.prettyPrinted, .sortedKeys])
    guard faviconData.count <= 4096 else {
      throw HostProbeFailure("Favicon proof exceeded size bound.")
    }
    try faviconData.write(
      to: root.appending(path: "\(phase)-native-favicon.json"), options: .atomic)
    try expect(
      matchesAuthoredIcon(image) && size.width > 0 && size.height > 0
        && size.width <= 256 && size.height <= 256
        && targetChanges > 0,
      "Chromium favicon becomes a bounded native image and publishes owned tab change")
  }

  private func capture(_ view: NSView, index: Int) async throws {
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw HostProbeFailure("Native host capture failed.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw HostProbeFailure("Native host PNG failed.")
    }
    try png.write(to: root.appending(path: "\(phase)-native-host-\(index).png"), options: .atomic)
  }

  private func captureEditor(_ store: BrowserStore) async throws {
    let view = NSHostingView(
      rootView: SpaceEditor(store: store, route: .edit(store.session.selectedSpaceID))
        .environment(\.colorScheme, .light).frame(width: 496, height: 430))
    let carrier = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 496, height: 430), styleMask: .borderless,
      backing: .buffered, defer: false)
    carrier.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw HostProbeFailure("Host Space editor capture failed.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw HostProbeFailure("Host Space editor PNG failed.")
    }
    try png.write(to: root.appending(path: "\(phase)-host-space-editor.png"), options: .atomic)
    withExtendedLifetime(carrier) {}
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw HostProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "favicon": faviconProof as Any? ?? NSNull(),
        "closedWindows": Dictionary(
          uniqueKeysWithValues: closures.map { ($0.key.uuidString, $0.value) }),
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Production host class with hidden native windows, actual NSMenu target actions, injected owned key-window identity and notifications, real native ordinary closures, managed restoration/geometry, cross-process lock, and engine-quit audit. Engine-requested normal-profile windows have a separate report. Physical input/focus, native close-cancellation dialogs, primary/last-engine-window macOS reopen policy, private sessions and third-party window flows are not covered.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-native-host.json"), options: .atomic)
  }
}

private struct HostProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
