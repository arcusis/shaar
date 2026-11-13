// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Observation
import SwiftUI
import os

typealias ProfileDownloadDirectoryApplier = @MainActor (UUID, URL?) async throws -> URL?
typealias ProfileDirectoryRemovalOperation = @Sendable (URL?) async throws -> Void

@MainActor @Observable
final class BrowserSettingsState {
  let workspace: BrowserWorkspaceStore
  let preferences: BrowserPreferencesStore
  let runtime: ARCChromiumRuntime?
  let sharedExtensions: SharedExtensionSettingsModel?
  let profileBackend: (any ProfileSettingsBackend)?
  private(set) var deletingProfileID: UUID?
  private(set) var selectedProfileID: UUID?
  private(set) var downloadDirectoryRevision = 0
  private(set) var downloadDirectoryErrors: [UUID: String] = [:]
  private var downloadDirectoryRequests: [UUID: UUID] = [:]
  private var didPresent = false
  let downloadDirectorySettingsEnabled: Bool
  private let applyDownloadDirectoryToEngine: ProfileDownloadDirectoryApplier?
  private let removeProfileDirectory: ProfileDirectoryRemovalOperation
  var onOpenSpace: (UUID) -> Void = { _ in }
  var onConnectAccount: (UUID, AccountSignInOption) -> Void = { _, _ in }
  var onDisconnectAccount: (UUID, AccountProvider) -> Void = { _, _ in }
  var onAddProfile: () -> Void = {}
  var onRestart: (() -> String?)?

  init(
    workspace: BrowserWorkspaceStore, preferences: BrowserPreferencesStore,
    runtime: ARCChromiumRuntime? = nil, profileBackend: (any ProfileSettingsBackend)? = nil,
    sharedExtensions: SharedExtensionSettingsModel? = nil,
    downloadDirectorySettingsEnabled: Bool = false,
    applyDownloadDirectory: ProfileDownloadDirectoryApplier? = nil,
    removeProfileDirectory: @escaping ProfileDirectoryRemovalOperation = { directory in
      try await ProfileDataDirectoryRemoval.removeIfPresent(at: directory)
    }
  ) {
    self.workspace = workspace
    self.preferences = preferences
    self.runtime = runtime
    self.sharedExtensions = sharedExtensions
    self.profileBackend =
      profileBackend
      ?? runtime.map { engine in
        EngineProfileSettings(
          runtime: engine,
          httpsOnlyMode: { preferences.httpsOnlyChoice(for: $0) })
      }
    applyDownloadDirectoryToEngine = applyDownloadDirectory
    self.removeProfileDirectory = removeProfileDirectory
    self.downloadDirectorySettingsEnabled =
      downloadDirectorySettingsEnabled && applyDownloadDirectory != nil
  }

  var profiles: [BrowserSettingsProfile] {
    _ = downloadDirectoryRevision
    return workspace.workspace.catalog.profiles.map { profile in
      let spaces = workspace.workspace.catalog.spaces.filter { $0.profileID == profile.id }
      return BrowserSettingsProfile(
        id: profile.id, name: profile.name, color: ProfileColorChoice(profile: profile),
        symbol: profile.displaySymbol,
        spaces: spaces.map { BrowserSettingsSpace(id: $0.id, name: $0.name, symbol: $0.symbol) },
        accounts: preferences.accounts(for: profile.id),
        downloadDirectory: preferences.downloadDirectory(for: profile.id),
        defaultDownloadDirectory: runtime?.downloadsDirectory(forProfileID: profile.id.uuidString),
        canChooseDownloadDirectory: downloadDirectorySettingsEnabled)
    }
  }

  func extensionManager(for profileID: UUID) -> ExtensionManagerModel? {
    guard let runtime,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID })
    else { return nil }
    return ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)
  }

  func openExtensions(for profileID: UUID) {
    let focused = workspace.workspace.focusedWindowID.flatMap { workspace.stores[$0] }
    let store =
      (focused?.session.spaces.contains { $0.profileID == profileID } == true ? focused : nil)
      ?? workspace.stores.values.first(where: {
        $0.session.spaces.contains { $0.profileID == profileID }
      })
    guard let store,
      let firstSpaceID = store.session.spaces.first(where: { $0.profileID == profileID })?.id
    else {
      return
    }
    let spaceID =
      store.session.selectedSpace.profileID == profileID
      ? store.session.selectedSpaceID : firstSpaceID
    if store.session.selectedSpaceID != spaceID { store.perform(.space(spaceID)) }
    store.perform(.open(BrowserExtension.storeCatalogURL))
  }

  func selectedTabID(for profileID: UUID) -> UUID? {
    browserStoreForSiteAccess(profileID: profileID, keyWindow: NSApp.keyWindow)?.session
      .selectedPage?.tab.id
  }

  func pageOrigin(for profileID: UUID) -> String? {
    guard
      let url = browserStoreForSiteAccess(profileID: profileID, keyWindow: NSApp.keyWindow)?
        .session.selectedPage?.tab.url
    else { return nil }
    return ExtensionPageOrigin.string(from: url)
  }

  /// The browser window the user is looking at. Settings is often key, so the focused
  /// browser window is the next choice. Another window is not a guess.
  func browserStoreForSiteAccess(profileID: UUID, keyWindow: NSWindow?) -> BrowserStore? {
    if let keyWindow, let store = store(for: keyWindow),
      store.session.selectedSpace.profileID == profileID
    {
      return store
    }
    if let focusedID = workspace.workspace.focusedWindowID,
      let focused = workspace.stores[focusedID],
      focused.session.selectedSpace.profileID == profileID
    {
      return focused
    }
    return nil
  }

  private func store(for window: NSWindow) -> BrowserStore? {
    guard let runtime else { return nil }
    for (id, store) in workspace.stores {
      if runtime.window(forID: id.uuidString) === window { return store }
    }
    return nil
  }

  func chooseUnpackedExtension(for profileID: UUID) {
    guard extensionManager(for: profileID) != nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = SettingsL10n.string("Choose")
    panel.message = SettingsL10n.string("Choose an unpacked extension folder.")
    if panel.runModal() == .OK, let url = panel.url {
      extensionManager(for: profileID)?.loadUnpacked(
        at: url, tabID: selectedTabID(for: profileID))
    }
  }

  var searchEngines: [BrowserSettingsChoice] {
    BrowserSearchEngine.allCases.map {
      BrowserSettingsChoice(id: $0.rawValue, title: $0.displayName)
    }
  }

  var selectedSearchEngine: String {
    guard let selectedProfileID,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == selectedProfileID })
    else { return BrowserSearchEngine.google.rawValue }
    return preferences.searchEngine(for: selectedProfileID).rawValue
  }

  var sidebarInitiallyVisible: Bool { preferences.sidebarInitiallyVisible }
  var storageNotice: String? { workspace.storageNotice ?? preferences.storageNotice }

  func prepareFirstPresentation(for profileID: UUID?) {
    if let profileID,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID })
    {
      didPresent = true
      selectedProfileID = profileID
    } else if !didPresent {
      didPresent = true
      selectedProfileID = nil
    }
  }

  @discardableResult
  func selectProfile(_ id: UUID?) -> Bool {
    guard let id, workspace.workspace.catalog.profiles.contains(where: { $0.id == id }) else {
      return false
    }
    selectedProfileID = id
    return true
  }

  @discardableResult
  func selectSearchEngine(_ rawValue: String, for profileID: UUID? = nil) -> Bool {
    guard let profileID = profileID ?? selectedProfileID,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID }),
      let engine = BrowserSearchEngine(rawValue: rawValue)
    else { return false }
    preferences.setSearchEngine(engine, for: profileID)
    return true
  }

  func setSidebarInitiallyVisible(_ value: Bool) {
    preferences.setSidebarInitiallyVisible(value)
  }

  func chooseDownloadDirectory(for profileID: UUID) {
    guard downloadDirectorySettingsEnabled,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID })
    else {
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = SettingsL10n.string("Choose")
    panel.message = SettingsL10n.string("Choose a download folder for this profile.")
    if panel.runModal() == .OK, let url = panel.url {
      Task { _ = await applyDownloadDirectory(url, for: profileID) }
    }
  }

  func resetDownloadDirectory(for profileID: UUID) {
    guard downloadDirectorySettingsEnabled,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID })
    else {
      return
    }
    Task { _ = await applyDownloadDirectory(nil, for: profileID) }
  }

  @discardableResult
  func applyDownloadDirectory(_ directory: URL?, for profileID: UUID) async -> Bool {
    guard !Task.isCancelled, downloadDirectorySettingsEnabled,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID }),
      let applyDownloadDirectoryToEngine
    else { return false }
    let request = UUID()
    downloadDirectoryRequests[profileID] = request
    if let directory, !DownloadDirectoryPolicy.validate(directory, bundleURL: Bundle.main.bundleURL)
    {
      downloadDirectoryErrors[profileID] = SettingsL10n.string(
        "The download folder could not be changed. Try again.")
      downloadDirectoryRequests[profileID] = nil
      return false
    }
    do {
      let acknowledged = try await applyDownloadDirectoryToEngine(profileID, directory)
      guard !Task.isCancelled else {
        if downloadDirectoryRequests[profileID] == request {
          downloadDirectoryRequests[profileID] = nil
        }
        return false
      }
      guard downloadDirectoryRequests[profileID] == request else { return false }
      guard workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID }) else {
        downloadDirectoryRequests[profileID] = nil
        return false
      }
      if directory != nil && acknowledged == nil {
        downloadDirectoryErrors[profileID] = SettingsL10n.string(
          "The download folder could not be changed. Try again.")
        downloadDirectoryRequests[profileID] = nil
        return false
      }
      preferences.setDownloadDirectory(directory == nil ? nil : acknowledged, for: profileID)
      downloadDirectoryErrors[profileID] = nil
      downloadDirectoryRevision &+= 1
      downloadDirectoryRequests[profileID] = nil
      return true
    } catch is CancellationError {
      if downloadDirectoryRequests[profileID] == request {
        downloadDirectoryRequests[profileID] = nil
      }
      return false
    } catch {
      guard downloadDirectoryRequests[profileID] == request else { return false }
      downloadDirectoryErrors[profileID] = SettingsL10n.string(
        "The download folder could not be changed. Try again.")
      downloadDirectoryRequests[profileID] = nil
      return false
    }
  }

  @discardableResult
  func createProfile(name: String) -> UUID? {
    do {
      let id = try workspace.createProfile(name: name)
      selectedProfileID = id
      return id
    } catch { return nil }
  }

  @discardableResult
  func renameProfile(_ id: UUID, name: String) -> Bool {
    do {
      try workspace.renameProfile(id, name: name)
      return true
    } catch { return false }
  }

  @discardableResult
  func setProfileColor(_ id: UUID, to color: ProfileColorChoice) -> Bool {
    do {
      try workspace.setProfileColor(id, tint: color.tint, customRGB: color.customRGB)
      return true
    } catch { return false }
  }

  @discardableResult
  func setProfileSymbol(_ id: UUID, to symbol: String) -> Bool {
    do {
      try workspace.setProfileSymbol(id, symbol: symbol)
      return true
    } catch { return false }
  }

  func deleteProfile(_ id: UUID, movingSpacesTo destinationID: UUID?) async throws {
    guard deletingProfileID == nil, let profileBackend else {
      throw CocoaError(.featureUnsupported)
    }
    deletingProfileID = id
    defer { deletingProfileID = nil }
    // Validate before touching engine data; revalidate after loading an unused profile.
    var draft = workspace.workspace
    try draft.deleteProfile(id, movingSpacesTo: destinationID)
    try preferences.validateProfileRemoval()
    try await profileBackend.loadProfile(id)
    let profileDirectory = runtime?.profileDataDirectory(forProfileID: id.uuidString)
    if runtime != nil && profileDirectory == nil {
      throw CocoaError(.fileNoSuchFile)
    }
    draft = workspace.workspace
    try draft.deleteProfile(id, movingSpacesTo: destinationID)
    try workspace.validateWritableSnapshot()
    try await profileBackend.deleteProfile(id)
    try workspace.deleteProfile(id, movingSpacesTo: destinationID)
    if selectedProfileID == id {
      _ = selectProfile(destinationID ?? workspace.workspace.catalog.profiles.first?.id)
    }
    try preferences.removeProfile(id)
    try workspace.flushSaves()
    do {
      try await removeProfileDirectory(profileDirectory)
    } catch {
      let message = error.localizedDescription
      Logger(subsystem: "org.arcusis.shaar", category: "profiles").error(
        "Deleted profile data could not be removed: \(message, privacy: .public)")
    }
  }

}

enum ProfileDataDirectoryRemoval {
  static func removeIfPresent(
    at directory: URL?,
    fileExists: @escaping @Sendable (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path)
    },
    removeItem: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) async throws {
    guard let directory else { return }
    try await Task.detached(priority: .utility) {
      for attempt in 0..<50 {
        do {
          guard fileExists(directory) else { return }
          try removeItem(directory)
          return
        } catch {
          guard fileExists(directory) else { return }
          guard attempt < 49 else { throw error }
          try await Task.sleep(for: .milliseconds(100))
        }
      }
    }.value
  }
}

enum DownloadDirectoryPolicy {
  static func validate(_ candidate: URL, bundleURL: URL, fileManager: FileManager = .default)
    -> Bool
  {
    guard candidate.isFileURL else { return false }
    let directory = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    guard directory.path != bundle.path,
      !directory.path.hasPrefix(bundle.path.hasSuffix("/") ? bundle.path : bundle.path + "/"),
      fileManager.isWritableFile(atPath: directory.path)
    else { return false }
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

private struct BrowserSettingsRoot: View {
  let state: BrowserSettingsState
  var initialSection: BrowserSettingsSection = .general
  var confirmsClearHistoryOnAppear = false

  var body: some View {
    BrowserSettingsView(
      profiles: state.profiles, searchEngines: state.searchEngines,
      selectedProfileID: Binding(
        get: { state.selectedProfileID }, set: { _ = state.selectProfile($0) }),
      sidebarInitiallyVisible: Binding(
        get: { state.sidebarInitiallyVisible }, set: { state.setSidebarInitiallyVisible($0) }),
      selectedSearchEngine: Binding(
        get: { state.selectedSearchEngine }, set: { _ = state.selectSearchEngine($0) }),
      storageNotice: state.storageNotice,
      downloadDirectoryErrors: state.downloadDirectoryErrors,
      onRestart: state.onRestart,
      onAddProfile: state.onAddProfile,
      onRenameProfile: { state.renameProfile($0, name: $1) },
      onSetProfileColor: { state.setProfileColor($0, to: $1) },
      onSetProfileSymbol: { state.setProfileSymbol($0, to: $1) },
      onChooseDownloadDirectory: { state.chooseDownloadDirectory(for: $0) },
      onResetDownloadDirectory: { state.resetDownloadDirectory(for: $0) },
      onDeleteProfile: { try await state.deleteProfile($0, movingSpacesTo: $1) },
      onOpenSpace: state.onOpenSpace,
      onConnectAccount: state.onConnectAccount,
      onDisconnectAccount: state.onDisconnectAccount,
      extensionManager: state.extensionManager(for:),
      sharedExtensions: state.sharedExtensions,
      onAddExtensions: { state.openExtensions(for: $0) },
      onLoadUnpacked: { state.chooseUnpackedExtension(for: $0) },
      pageOrigin: { state.pageOrigin(for: $0) },
      selectedTabID: { state.selectedTabID(for: $0) },
      profileBackend: state.profileBackend,
      clearHistory: state.runtime.map { runtime in
        { profileID in try await SettingsHistory.clear(runtime: runtime, profileID: profileID) }
      },
      httpsOnlyModeEnabled: { state.preferences.httpsOnlyModeEnabled(for: $0) },
      onSetHttpsOnlyMode: { profileID, enabled in
        state.preferences.setHttpsOnlyMode(enabled, for: profileID)
        guard let runtime = state.runtime as? ARCShaarRuntime else { return false }
        return runtime.setHttpsOnlyModeEnabled(enabled, forProfileID: profileID.uuidString)
      }, initialSection: initialSection,
      confirmsClearHistoryOnAppear: confirmsClearHistoryOnAppear)
  }
}

@MainActor
private final class BrowserSettingsWindowDelegate: NSObject, NSWindowDelegate {
  weak var controller: BrowserSettingsController?

  init(controller: BrowserSettingsController) {
    self.controller = controller
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    controller?.close()
    return false
  }
}

@MainActor
final class BrowserSettingsController: NSObject {
  enum Presentation { case visible, hiddenProbe }

  let state: BrowserSettingsState
  let presentation: Presentation
  private var windowDelegate: BrowserSettingsWindowDelegate?
  private(set) var window: NSWindow?
  private(set) var initialSection: BrowserSettingsSection = .general
  private(set) var confirmsClearHistoryOnAppear = false

  init(
    workspace: BrowserWorkspaceStore, preferences: BrowserPreferencesStore,
    runtime: ARCChromiumRuntime? = nil,
    sharedExtensions: SharedExtensionSettingsModel? = nil,
    downloadDirectoryApplier: ProfileDownloadDirectoryApplier? = nil,
    presentation: Presentation = .visible
  ) {
    state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, runtime: runtime,
      sharedExtensions: sharedExtensions,
      downloadDirectorySettingsEnabled: downloadDirectoryApplier != nil,
      applyDownloadDirectory: downloadDirectoryApplier)
    self.presentation = presentation
    super.init()
  }

  var profiles: [BrowserSettingsProfile] { state.profiles }
  var selectedProfileID: UUID? { state.selectedProfileID }
  var sidebarInitiallyVisible: Bool { state.sidebarInitiallyVisible }

  func setOpenSpaceHandler(_ handler: @escaping (UUID) -> Void) {
    state.onOpenSpace = handler
  }

  func setAccountHandlers(
    connect: @escaping (UUID, AccountSignInOption) -> Void,
    disconnect: @escaping (UUID, AccountProvider) -> Void
  ) {
    state.onConnectAccount = connect
    state.onDisconnectAccount = disconnect
  }

  func setAddProfileHandler(_ handler: @escaping () -> Void) {
    state.onAddProfile = handler
  }

  func setRestartHandler(_ handler: @escaping () -> String?) {
    state.onRestart = handler
  }

  @discardableResult
  func selectProfile(_ id: UUID?) -> Bool { state.selectProfile(id) }

  @discardableResult
  func selectSearchEngine(_ rawValue: String, for profileID: UUID? = nil) -> Bool {
    state.selectSearchEngine(rawValue, for: profileID)
  }

  func setSidebarInitiallyVisible(_ value: Bool) { state.setSidebarInitiallyVisible(value) }

  @discardableResult
  func createProfile(name: String) -> UUID? { state.createProfile(name: name) }

  @discardableResult
  func renameProfile(_ id: UUID, name: String) -> Bool { state.renameProfile(id, name: name) }

  @discardableResult
  func setProfileColor(_ id: UUID, to color: ProfileColorChoice) -> Bool {
    state.setProfileColor(id, to: color)
  }

  @discardableResult
  func setProfileSymbol(_ id: UUID, to symbol: String) -> Bool {
    state.setProfileSymbol(id, to: symbol)
  }

  func show(
    for profileID: UUID? = nil, section: BrowserSettingsSection = .general,
    confirmsClearHistory: Bool = false
  ) {
    state.prepareFirstPresentation(for: profileID)
    initialSection = section
    confirmsClearHistoryOnAppear = confirmsClearHistory
    let settingsWindow = makeWindowIfNeeded()
    settingsWindow.contentView = NSHostingView(
      rootView: BrowserSettingsRoot(
        state: state, initialSection: section,
        confirmsClearHistoryOnAppear: confirmsClearHistory).settingsLocalization())
    if presentation == .visible {
      settingsWindow.makeKeyAndOrderFront(nil)
    } else {
      settingsWindow.orderOut(nil)
    }
  }

  func showClearHistory(for profileID: UUID?) {
    show(for: profileID, section: .privacy, confirmsClearHistory: true)
  }

  func close() {
    window?.orderOut(nil)
  }

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    settingsWindow.title = SettingsL10n.string("Settings")
    settingsWindow.minSize = NSSize(width: 620, height: 500)
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.contentView = NSHostingView(
      rootView: BrowserSettingsRoot(
        state: state, initialSection: initialSection,
        confirmsClearHistoryOnAppear: confirmsClearHistoryOnAppear).settingsLocalization())
    settingsWindow.center()
    let delegate = BrowserSettingsWindowDelegate(controller: self)
    windowDelegate = delegate
    settingsWindow.delegate = delegate
    window = settingsWindow
    return settingsWindow
  }
}
