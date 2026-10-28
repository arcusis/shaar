import AppKit
import BrowserCore
import Observation
import SwiftUI

@MainActor @Observable
private final class BrowserSettingsState {
  let workspace: BrowserWorkspaceStore
  let preferences: BrowserPreferencesStore
  let nativeBitwardenController: NativeBitwardenController
  private(set) var selectedProfileID: UUID?
  private var didPresent = false

  init(
    workspace: BrowserWorkspaceStore, preferences: BrowserPreferencesStore,
    nativeBitwardenBackend: any NativeBitwardenBackend = NativeBitwardenSDKBackend(),
    credentialStore: PasswordCredentialStore = PasswordCredentialStore()
  ) {
    self.workspace = workspace
    self.preferences = preferences
    nativeBitwardenController = NativeBitwardenController(
      preferences: preferences, backend: nativeBitwardenBackend,
      credentialStore: credentialStore)
  }

  var profiles: [BrowserSettingsProfile] {
    workspace.workspace.catalog.profiles.map { profile in
      let spaces = workspace.workspace.catalog.spaces.filter { $0.profileID == profile.id }
      return BrowserSettingsProfile(
        id: profile.id, name: profile.name, spaceCount: spaces.count,
        spaceNames: spaces.map(\.name))
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
    guard !didPresent else { return }
    didPresent = true
    guard let profileID,
      workspace.workspace.catalog.profiles.contains(where: { $0.id == profileID })
    else {
      selectedProfileID = nil
      nativeBitwardenController.selectProfile(nil)
      return
    }
    selectedProfileID = profileID
    nativeBitwardenController.selectProfile(profileID)
  }

  @discardableResult
  func selectProfile(_ id: UUID?) -> Bool {
    guard let id, workspace.workspace.catalog.profiles.contains(where: { $0.id == id }) else {
      return false
    }
    selectedProfileID = id
    nativeBitwardenController.selectProfile(id)
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

  @discardableResult
  func createProfile(name: String) -> UUID? {
    do {
      let id = try workspace.createProfile(name: name)
      selectedProfileID = id
      nativeBitwardenController.selectProfile(id)
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
}

private struct BrowserSettingsRoot: View {
  let state: BrowserSettingsState

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
      onCreateProfile: { state.createProfile(name: $0) },
      onRenameProfile: { state.renameProfile($0, name: $1) },
      nativeBitwardenController: state.nativeBitwardenController)
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

  private let state: BrowserSettingsState
  let presentation: Presentation
  private var windowDelegate: BrowserSettingsWindowDelegate?
  private(set) var window: NSWindow?

  init(
    workspace: BrowserWorkspaceStore, preferences: BrowserPreferencesStore,
    presentation: Presentation = .visible,
    nativeBitwardenBackend: any NativeBitwardenBackend = NativeBitwardenSDKBackend(),
    credentialStore: PasswordCredentialStore = PasswordCredentialStore()
  ) {
    state = BrowserSettingsState(
      workspace: workspace, preferences: preferences,
      nativeBitwardenBackend: nativeBitwardenBackend, credentialStore: credentialStore)
    self.presentation = presentation
    super.init()
  }

  var profiles: [BrowserSettingsProfile] { state.profiles }
  var selectedProfileID: UUID? { state.selectedProfileID }
  var nativeBitwardenController: NativeBitwardenController { state.nativeBitwardenController }
  var selectedSearchEngine: String { state.selectedSearchEngine }
  var sidebarInitiallyVisible: Bool { state.sidebarInitiallyVisible }

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

  func show(for profileID: UUID? = nil) {
    state.prepareFirstPresentation(for: profileID)
    let settingsWindow = makeWindowIfNeeded()
    if presentation == .visible {
      settingsWindow.makeKeyAndOrderFront(nil)
    } else {
      settingsWindow.orderOut(nil)
    }
  }

  func close() {
    state.nativeBitwardenController.closeSettings()
    window?.orderOut(nil)
  }

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    settingsWindow.title = "Settings"
    settingsWindow.minSize = NSSize(width: 620, height: 500)
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.contentView = NSHostingView(rootView: BrowserSettingsRoot(state: state))
    settingsWindow.center()
    let delegate = BrowserSettingsWindowDelegate(controller: self)
    windowDelegate = delegate
    settingsWindow.delegate = delegate
    window = settingsWindow
    return settingsWindow
  }
}
