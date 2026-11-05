// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ProfilePrivacyTests {
  @Test func settingsUseSelectedShaarRuntimeForPrivacyBackend() throws {
    let runtime = ARCShaarRuntime()
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore(), runtime: runtime)
    #expect((state.profileBackend as? EngineProfileSettings)?.runtime === runtime)
    #expect(state.selectProfile(workspace.workspace.catalog.profiles[1].id))
    #expect(state.selectedProfileID == workspace.workspace.catalog.profiles[1].id)
  }

  @Test func unavailableShaarCookiePolicyStaysUnknown() async {
    let runtime = ARCShaarRuntime()
    let profileID = UUID().uuidString
    await withCheckedContinuation { continuation in
      runtime.refreshThirdPartyCookiePolicy(forProfileID: profileID) {
        continuation.resume()
      }
    }
    #expect(runtime.thirdPartyCookiesBlocked(forProfileID: profileID) == nil)
    #expect(runtime.thirdPartyCookiesManaged(forProfileID: profileID) == nil)
  }

  @Test func unavailableEngineFailsClosedForProfileAndCookieMutations() async {
    let backend = EngineProfileSettings(runtime: ARCChromiumRuntime())
    let id = UUID()
    await #expect(throws: (any Error).self) { try await backend.loadProfile(id) }
    #expect(backend.thirdPartyCookiesBlocked(id) == nil)
    await #expect(throws: (any Error).self) {
      try await backend.setThirdPartyCookiesBlocked(true, profileID: id)
    }
    await #expect(throws: (any Error).self) { try await backend.deleteProfile(id) }
  }

  @Test func supportedCookiePolicyReadsBackAndFailureKeepsPreviousValue() async {
    let backend = ProfileSettingsStub()
    let id = UUID()
    let other = UUID()
    backend.cookiePolicies = [id: false, other: false]
    let model = ProfilePrivacyModel(profileID: id, backend: backend)
    await model.load()
    await model.setCookiesBlocked(true)
    #expect(model.cookiesBlocked == true && backend.cookiePolicies[other] == false)
    backend.failureAction = "cookies"
    await model.setCookiesBlocked(false)
    #expect(model.cookiesBlocked == true && model.failure != nil)
  }

  @Test func ignoredCookiePolicyWriteReportsFailureAfterReadback() async {
    let backend = ProfileSettingsStub()
    let profileID = UUID()
    backend.cookiePolicies[profileID] = false
    backend.ignoreCookieWrites = true
    let model = ProfilePrivacyModel(profileID: profileID, backend: backend)
    await model.load()

    await model.setCookiesBlocked(true)

    #expect(model.cookiesBlocked == false)
    #expect(model.failure != nil)
  }

  @Test func managedCookiePolicyStaysReadOnlyForSelectedProfile() async {
    let backend = ProfileSettingsStub()
    let selected = UUID()
    let other = UUID()
    backend.cookiePolicies = [selected: true, other: false]
    backend.managedCookieProfiles = [selected]
    let model = ProfilePrivacyModel(profileID: selected, backend: backend)
    await model.load()
    #expect(model.cookiesManaged)
    await model.setCookiesBlocked(false)
    #expect(model.cookiesBlocked == true)
    #expect(!backend.calls.contains { $0.0 == "cookies" })
    #expect(backend.cookiePolicies[other] == false)
  }

  @Test func selectedProfileOwnsEveryPrivacyActionAndUnsupportedCookiePolicyStaysUnknown() async {
    let backend = ProfileSettingsStub()
    let selected = UUID()
    let other = UUID()
    backend.exceptions[selected] = [
      "https://example.test": ["camera": ["value": "allow", "isDefault": false]]
    ]
    backend.exceptions[other] = [
      "https://other.test": ["camera": ["value": "block", "isDefault": false]]
    ]
    let model = ProfilePrivacyModel(profileID: selected, backend: backend)
    await model.load()
    #expect(model.loaded && model.failure == nil)
    #expect(model.sites.map(\.id) == ["https://example.test"])
    #expect(model.sites.first?.permissions.first?.value == .allow)
    #expect(model.cookiesBlocked == nil)
    await model.setCookiesBlocked(true)
    #expect(!backend.calls.contains { $0.0 == "cookies" })
    await model.clear(siteData: true)
    await model.clear(siteData: false)
    await model.resetPermissions(origin: "https://example.test")
    #expect(model.sites.isEmpty)
    #expect(backend.exceptions[other]?.count == 1)
    #expect(backend.calls.allSatisfy { $0.1 == selected })
    #expect(backend.calls.filter { ["data", "cache", "reset"].contains($0.0) }.count == 3)
  }

  @Test func lateProfileCompletionCannotReplaceNewProfileState() async {
    let backend = ProfileSettingsStub()
    let first = UUID()
    let second = UUID()
    backend.exceptions[first] = [
      "https://first.test": ["camera": ["value": "allow", "isDefault": false]]
    ]
    backend.exceptions[second] = [:]
    backend.delayedProfile = first
    let old = ProfilePrivacyModel(profileID: first, backend: backend)
    let pending = Task { await old.load() }
    while backend.loadContinuation == nil { await Task.yield() }
    let current = ProfilePrivacyModel(profileID: second, backend: backend)
    await current.load()
    backend.loadContinuation?.resume()
    await pending.value
    #expect(old.sites.map(\.id) == ["https://first.test"])
    #expect(current.sites.isEmpty && current.profileID == second)
  }

  @Test func engineFailureNeverReportsClearOrRevokeSuccess() async {
    let backend = ProfileSettingsStub()
    let id = UUID()
    backend.exceptions[id] = [
      "https://example.test": ["camera": ["value": "allow", "isDefault": false]]
    ]
    let model = ProfilePrivacyModel(profileID: id, backend: backend)
    await model.load()
    backend.failureAction = "data"
    await model.clear(siteData: true)
    #expect(model.failure != nil && model.message == nil && !model.busy)
    backend.failureAction = "reset"
    await model.resetPermissions(origin: "https://example.test")
    #expect(model.failure != nil && model.sites.count == 1 && model.message == nil)
  }

  @Test func defaultsOmittedAndMalformedExceptionsRejected() throws {
    #expect(
      try ProfileSitePermission.exceptions(["camera": ["value": "default", "isDefault": true]])
        .isEmpty)
    #expect(throws: (any Error).self) {
      try ProfileSitePermission.exceptions(["camera": ["value": "invalid", "isDefault": false]])
    }
  }

  @Test func deletionWaitsForEngineAndRemovesAllPreferencesAcrossReload() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferencesURL = root.appending(path: "preferences.json")
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "legacy.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let source = workspace.workspace.catalog.profiles[0].id
    let other = workspace.workspace.catalog.profiles[1].id
    let preferences = BrowserPreferencesStore(fileURL: preferencesURL)
    for id in [source, other] {
      preferences.setSearchEngine(.bing, for: id)
      preferences.setDownloadDirectory(root.appending(path: id.uuidString), for: id)
      preferences.setExtension("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", pinned: true, for: id)
      preferences.setAccount(.init(provider: .google, email: "test@example.test"), for: id)
      preferences.setAutomaticPictureInPicture(false, on: "https://example.test", for: id)
      var simulation = DeveloperSimulation()
      simulation.darkMode = true
      preferences.setDeveloperSimulation(simulation, on: "https://example.test", for: id)
    }
    preferences.setSidebarInitiallyVisible(false)
    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, profileBackend: backend)
    _ = state.selectProfile(source)
    let before = workspace.workspace
    backend.failureAction = "delete"
    await #expect(throws: (any Error).self) {
      try await state.deleteProfile(source, movingSpacesTo: other)
    }
    #expect(workspace.workspace == before)
    #expect(preferences.searchEngine(for: source) == .bing)
    #expect(
      preferences.downloadDirectory(for: source)?.path
        == root.appending(path: source.uuidString).path)
    backend.failureAction = nil
    try await state.deleteProfile(source, movingSpacesTo: other)
    #expect(state.selectedProfileID == other)
    #expect(backend.calls.last?.0 == "delete" && backend.calls.last?.1 == source)
    #expect(try file.load() == workspace.workspace)
    let reloaded = BrowserPreferencesStore(fileURL: preferencesURL)
    #expect(reloaded.searchEngine(for: source) == .google)
    #expect(reloaded.downloadDirectory(for: source) == nil)
    #expect(
      reloaded.downloadDirectory(for: other)?.path == root.appending(path: other.uuidString).path)
    #expect(
      reloaded.accounts(for: source).isEmpty && reloaded.pinnedExtensionIDs(for: source).isEmpty)
    #expect(reloaded.allowsAutomaticPictureInPicture(on: "https://example.test", for: source))
    #expect(!reloaded.developerSimulation(on: "https://example.test", for: source).isActive)
    #expect(reloaded.searchEngine(for: other) == .bing && !reloaded.sidebarInitiallyVisible)
    #expect(
      reloaded.accounts(for: other).count == 1 && reloaded.pinnedExtensionIDs(for: other).count == 1
    )
    #expect(!reloaded.allowsAutomaticPictureInPicture(on: "https://example.test", for: other))
    #expect(reloaded.developerSimulation(on: "https://example.test", for: other).isActive)
  }

  @Test func invalidDeletionNeverTouchesEngineOrPreferences() async throws {
    let workspace = try BrowserWorkspaceStore()
    let preferences = BrowserPreferencesStore()
    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, profileBackend: backend)
    let before = workspace.workspace
    await #expect(throws: (any Error).self) {
      try await state.deleteProfile(before.catalog.profiles[0].id, movingSpacesTo: UUID())
    }
    #expect(backend.calls.isEmpty && workspace.workspace == before)
  }

  @Test func preferenceWriteFailureBlocksEngineDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "preferences.json")
    let preferences = BrowserPreferencesStore(fileURL: url)
    let workspace = try BrowserWorkspaceStore()
    let source = workspace.workspace.catalog.profiles[0].id
    preferences.setSearchEngine(.bing, for: source)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, profileBackend: backend)
    let before = workspace.workspace
    await #expect(throws: (any Error).self) {
      try await state.deleteProfile(source, movingSpacesTo: before.catalog.profiles[1].id)
    }
    #expect(backend.calls.isEmpty && workspace.workspace == before)
    #expect(preferences.searchEngine(for: source) == .bing)
  }
}

@MainActor
final class ProfileSettingsStub: ProfileSettingsBackend {
  var exceptions: [UUID: [String: [String: NSDictionary]]] = [:]
  var calls: [(String, UUID)] = []
  var failureAction: String?
  var cookiePolicies: [UUID: Bool] = [:]
  var ignoreCookieWrites = false
  var managedCookieProfiles: Set<UUID> = []
  var delayedProfile: UUID?
  var loadContinuation: CheckedContinuation<Void, Never>?

  func record(_ action: String, _ id: UUID) throws {
    calls.append((action, id))
    if action == failureAction { throw CocoaError(.fileWriteUnknown) }
  }
  func loadProfile(_ id: UUID) async throws {
    try record("load", id)
    if id == delayedProfile {
      await withCheckedContinuation { loadContinuation = $0 }
    }
  }
  func clearSiteData(_ id: UUID) async throws { try record("data", id) }
  func clearCache(_ id: UUID) async throws { try record("cache", id) }
  func permissionOrigins(_ id: UUID) async throws -> [String] {
    try record("origins", id)
    return Array(exceptions[id, default: [:]].keys)
  }
  func permissions(_ id: UUID, origin: String) async throws -> [String: NSDictionary] {
    try record("permissions", id)
    return exceptions[id]?[origin] ?? [:]
  }
  func resetPermissions(_ id: UUID, origin: String) async throws {
    try record("reset", id)
    exceptions[id]?[origin] = nil
  }
  func thirdPartyCookiesBlocked(_ id: UUID) -> Bool? { cookiePolicies[id] }
  func thirdPartyCookiesManaged(_ id: UUID) -> Bool { managedCookieProfiles.contains(id) }
  func setThirdPartyCookiesBlocked(_ blocked: Bool, profileID: UUID) async throws {
    try record("cookies", profileID)
    if !ignoreCookieWrites { cookiePolicies[profileID] = blocked }
  }
  func deleteProfile(_ id: UUID) async throws { try record("delete", id) }
}
