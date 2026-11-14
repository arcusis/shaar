// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@MainActor
final class NativeBrowserMenu: NSMenu {
  @preconcurrency override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "n",
      modifiers == .command || modifiers == [.command, .shift]
        || modifiers == [.command, .option]
    {
      for section in items.compactMap(\.submenu) {
        guard let index = section.items.firstIndex(where: {
          $0.keyEquivalent.lowercased() == "n"
            && $0.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
              == modifiers
        }), section.items[index].isEnabled
        else { continue }
        section.performActionForItem(at: index)
        return true
      }
      return false
    }
    return super.performKeyEquivalent(with: event)
  }
}

private final class DownloadDirectoryContinuation: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<URL?, any Error>)
    case finished(Result<URL?, any Error>)
  }

  private let lock = NSLock()
  private var state = State.waiting

  func install(_ continuation: CheckedContinuation<URL?, any Error>) {
    lock.lock()
    switch state {
    case .waiting:
      state = .installed(continuation)
      lock.unlock()
    case .installed:
      lock.unlock()
      preconditionFailure("A download directory continuation can only be installed once.")
    case .finished(let result):
      lock.unlock()
      continuation.resume(with: result)
    }
  }

  func resume(_ result: Result<URL?, any Error>) {
    lock.lock()
    let continuation: CheckedContinuation<URL?, any Error>?
    switch state {
    case .waiting:
      state = .finished(result)
      continuation = nil
    case .installed(let installed):
      state = .finished(result)
      continuation = installed
    case .finished:
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(with: result)
  }
}

enum BrowserMenuCommand: String, CaseIterable {
  case newWindow, newPrivateWindow, newMiniWindow, newTab, search, newSpace, editSpace, closeTab, sharePage,
    print, closeWindow, addFavorite
  case openFile
  case reopenClosed, reopenClosedWindow, recentlyClosed, bookmarkPage, bookmarks, history,
    clearHistory, downloads, pasteAndGo
  case back, forward, find, findNext, findPrevious, sidebar, nextSpace, previousSpace, reload,
    hardReload, developerTools, chromiumDeveloperTools, zoomIn, zoomOut, actualSize
  case nextWindow, previousWindow
  case splitView
  case extensions, help, minimizeWindow, zoomWindow, bringAllToFront, fullScreen, settings, quit,
    createFolder
  case checkForUpdates, inspector, inspectorCopy, inspectorSource, inspectorAgentCopy
}

enum PageZoomMenuRouter {
  static func route(
    _ command: BrowserMenuCommand, focusedTabID: UUID?,
    perform: (String, UUID) -> Bool
  ) -> Bool {
    guard let focusedTabID else { return false }
    let action: String
    switch command {
    case .zoomIn: action = "in"
    case .zoomOut: action = "out"
    case .actualSize: action = "reset"
    default: return false
    }
    return perform(action, focusedTabID)
  }
}

@MainActor
final class NativeBrowserContext {
  let id: UUID
  let nativeID: String
  let window: NSWindow
  let store: BrowserStore
  let engine: BrowserEngine
  let hosting: NSHostingView<BrowserWindow>
  let contentView: NSView
  let titlebarDragView: NSView
  var observers: [NSObjectProtocol] = []
  var geometryTask: Task<Void, Never>?

  init(
    id: UUID, nativeID: String, window: NSWindow, store: BrowserStore, engine: BrowserEngine,
    hosting: NSHostingView<BrowserWindow>, contentView: NSView, titlebarDragView: NSView
  ) {
    self.id = id
    self.nativeID = nativeID
    self.window = window
    self.store = store
    self.engine = engine
    self.hosting = hosting
    self.contentView = contentView
    self.titlebarDragView = titlebarDragView
  }
}

/// The same host manages production windows and hidden disposable test windows.
@MainActor
final class NativeBrowserHost: NSObject, NSMenuItemValidation, NSMenuDelegate {
  enum Presentation { case visible, hiddenProbe }

  let events: BrowserRuntimeEvents
  let workspace: BrowserWorkspaceStore
  private(set) var contexts: [UUID: NativeBrowserContext] = [:]
  private var appClosingWindows: Set<UUID> = []
  private(set) var menu: NSMenu?
  private(set) var lastError: String?
  var lastClosedWindowSnapshot: WorkspaceWindow?
  private let presentation: Presentation
  private let usesPrimaryWindow: Bool
  private let keyWindow: () -> NSWindow?
  private let screens: () -> [NSRect]
  let preferences: BrowserPreferencesStore
  private let downloadDirectoryApplier: ProfileDownloadDirectoryApplier?
  let sharedExtensions: SharedExtensionSettingsModel?
  private(set) var settingsController: BrowserSettingsController?
  private var privateHost: PrivateBrowserHost?
  var privateWindowOwners: [PrivateBrowserHost.Owner] { privateHost?.ownedWindows ?? [] }
  private var miniWindows: [String: MiniBrowserController] = [:]
  private(set) var accountSignIns: [String: ProfileAccountSignIn] = [:]
  private(set) var profileOnboarding: ProfileOnboardingWindow?
  private(set) var firstRunSetup: FirstRunSetupWindow?
  private let firstRunMarker: URL?
  private var pendingURLs: [URL] = []
  private(set) var pendingFileURLs: [URL] = []
  private var claimedPrimary = false
  private var reopenHandlerInstalled = false
  private var fileOpenHandlerInstalled = false
  private var started = false
  private var startupFailed = false
  private(set) var restartRequested = false
  private var shortcutMonitor: Any?
  private var previousMenu: NSMenu?
  private var previousServicesMenu: NSMenu?
  private var previousWindowsMenu: NSMenu?
  private var previousHelpMenu: NSMenu?
  private var engineRequestedWindows: Set<String> = []
  private var authoredPopupWindows: Set<String> = []
  /// Set only by the production entry point; probes and tests never check for updates.
  var updater: AppUpdater?
  var onClosed: ((UUID, Bool) -> Void)?

  init(
    events: BrowserRuntimeEvents, workspace: BrowserWorkspaceStore,
    preferences: BrowserPreferencesStore = BrowserPreferencesStore(),
    sharedExtensions: SharedExtensionSettingsModel? = nil,
    presentation: Presentation = .visible, usesPrimaryWindow: Bool = true,
    firstRunMarker: URL? = nil,
    keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
    screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
  ) {
    self.events = events
    self.workspace = workspace
    self.preferences = preferences
    self.sharedExtensions = sharedExtensions
    self.firstRunMarker = firstRunMarker
    if let shaar = events.runtime as? ARCShaarRuntime {
      downloadDirectoryApplier = Self.makeDownloadDirectoryApplier(runtime: shaar)
    } else {
      downloadDirectoryApplier = nil
    }
    self.presentation = presentation
    self.usesPrimaryWindow = usesPrimaryWindow
    self.keyWindow = keyWindow
    self.screens = screens
    super.init()
    events.onQuitRequested = { [weak self] in
      self?.flushGeometry()
      self?.workspace.persistSnapshot()
    }
    events.onQuitCancelled = { [weak self] in self?.restartRequested = false }
  }

  static func makeDownloadDirectoryApplier(runtime: ARCShaarRuntime)
    -> ProfileDownloadDirectoryApplier
  {
    { profileID, directory in
      let gate = DownloadDirectoryContinuation()
      let acknowledged = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          gate.install(continuation)
          guard !Task.isCancelled else {
            gate.resume(.failure(CancellationError()))
            return
          }
          runtime.configureDownloadDirectory(directory, profileID: profileID.uuidString) {
            acknowledged, error in
            if let error {
              gate.resume(.failure(error))
            } else if let acknowledged {
              gate.resume(.success(acknowledged))
            } else {
              gate.resume(.failure(CocoaError(.fileWriteUnknown)))
            }
          }
        }
      } onCancel: {
        gate.resume(.failure(CancellationError()))
      }
      return acknowledged
    }
  }

  var activeContext: NativeBrowserContext? {
    var window = keyWindow()
    while let parent = window?.sheetParent { window = parent }
    if let owned = contexts.values.first(where: {
      $0.window === window && !$0.engine.isClosed
        && events.runtime.window(forID: $0.nativeID) != nil
    }) {
      return owned
    }
    return contexts.values.first {
      guard !$0.engine.isClosed, case .popup(let popup) = $0.engine.extensionPanel else {
        return false
      }
      return events.runtime.view(forExtensionPopupID: popup.id)?.window === window && window != nil
    }
  }

  private var activeBrowserStore: BrowserStore? {
    privateHost?.activeOwner?.store ?? activeContext?.store
  }

  static func copyURLMenuAvailable(in store: BrowserStore?, menusEnabled: Bool) -> Bool {
    menusEnabled && store?.session.selectedPage != nil
  }

  static func routeBack(tabID: UUID?, canGoBack: Bool, goBack: (String) -> Void) -> Bool {
    guard canGoBack, let tabID else { return false }
    goBack(tabID.uuidString)
    return true
  }

  static func routeForward(tabID: UUID?, canGoForward: Bool, goForward: (String) -> Void) -> Bool {
    guard canGoForward, let tabID else { return false }
    goForward(tabID.uuidString)
    return true
  }

  static func printCommandIsAvailable(
    hasSelectedPage: Bool, commandIsOpen: Bool, hasNativePrint: Bool
  ) -> Bool {
    hasSelectedPage && !commandIsOpen && hasNativePrint
  }

  static func settingsSpaceSelectionShouldPresentWindow(in presentation: Presentation) -> Bool {
    presentation == .visible
  }

  static func reopenClosedShortcutCommand(
    canReopenTab: Bool, hasClosedWindow: Bool
  ) -> BrowserMenuCommand? {
    if canReopenTab { return .reopenClosed }
    return hasClosedWindow ? .reopenClosedWindow : nil
  }

  private var miniWindowTarget: NativeBrowserContext? {
    activeContext ?? workspace.workspace.focusedWindowID.flatMap { contexts[$0] }
      ?? contexts.values.first
  }

  func restore() throws {
    guard !started else { throw WorkspaceError.invalidState }
    started = true
    if presentation == .visible
      && BrowserRestart.startsFresh(arguments: ProcessInfo.processInfo.arguments)
    {
      let oldWindows = workspace.workspace.windows.map(\.id)
      _ = try workspace.newWindow(from: workspace.workspace.focusedWindowID)
      for id in oldWindows { try workspace.removeWindow(id) }
    }
    if workspace.workspace.windows.isEmpty { try workspace.newWindow() }
    workspace.persistSnapshot()
    let focused = workspace.workspace.focusedWindowID
    for record in workspace.workspace.windows { try attach(record.id, source: nil) }
    let privateHost = PrivateBrowserHost(
      runtime: events.runtime, presentsWindows: presentation == .visible,
      keyWindow: keyWindow,
      preferences: preferences,
      profileIsDownloading: { [weak self] profileID in
        self?.contexts.values.contains { context in
          context.engine.downloads.items(in: profileID).contains { $0.state == .downloading }
        } ?? false
      },
      sourceProfileID: { [weak self] in
        self?.privateWindowSourceProfileID()
      })
    self.privateHost = privateHost
    privateHost.installCallbacks()
    events.onWindowRequest = { [weak self] profile, type, userGesture in
      self?.requestedWindow(profile: profile, type: type, userGesture: userGesture)
    }
    events.onTabClosed = { [weak self] _, windowID in
      self?.closeEmptyAuthoredPopup(windowID: windowID)
    }
    events.onWindowShowRequest = { [weak self] window, active in
      self?.showRequestedWindow(window, active: active)
    }
    events.onDevToolsOpenURLRequest = { [weak self] payload in
      self?.openDevToolsRequestedURL(payload)
    }
    events.onNewTabWillAdopt = { [weak self] tab, profile, opener in
      self?.prepareNewTab(tab, profile: profile, opener: opener)
    }
    settingsController = BrowserSettingsController(
      workspace: workspace, preferences: preferences, runtime: events.runtime,
      sharedExtensions: sharedExtensions,
      downloadDirectoryApplier: downloadDirectoryApplier,
      presentation: presentation == .visible ? .visible : .hiddenProbe)
    settingsController?.setOpenSpaceHandler { [weak self] in self?.openSpaceFromSettings($0) }
    settingsController?.setAccountHandlers(
      connect: { [weak self] profile, option in
        self?.runSavedProfileSignIn(
          profile, provider: option.provider, purpose: .signIn, option: option)
      },
      disconnect: { [weak self] profile, provider in
        self?.runSavedProfileSignIn(profile, provider: provider, purpose: .signOut)
      })
    settingsController?.setAddProfileHandler { [weak self] in self?.presentNewProfile() }
    settingsController?.setRestartHandler { [weak self] in
      self?.restartForLanguageChange()
    }
    installMenus()
    if presentation == .visible {
      for context in contexts.values where context.id != focused { context.window.orderFront(nil) }
      (focused.flatMap { contexts[$0] } ?? contexts.values.first)?.window.makeKeyAndOrderFront(nil)
      if let firstRunMarker,
        let context = focused.flatMap({ contexts[$0] }) ?? contexts.values.first
      {
        let setup = FirstRunSetupWindow(
          store: context.store, marker: firstRunMarker,
          location: FirstRunLocation(application: Bundle.main.bundleURL))
        setup.onClose = { [weak self] in self?.firstRunSetup = nil }
        firstRunSetup = setup
        setup.show()
      }
    }
    for url in pendingURLs { openExternalURL(url) }
    pendingURLs.removeAll()
    for url in pendingFileURLs { openFileURL(url) }
    pendingFileURLs.removeAll()
  }

  @discardableResult
  func newWindow(from sourceID: UUID? = nil) throws -> UUID {
    guard started, !events.runtime.isQuitting else { throw WorkspaceError.invalidState }
    let source = sourceID.flatMap { contexts[$0]?.window.frame }
    let id = try workspace.newWindow(from: sourceID)
    do { try attach(id, source: source) } catch {
      try? workspace.removeWindow(id)
      if events.runtime.window(forID: id.uuidString) != nil {
        events.runtime.closeWindowID(id.uuidString)
      }
      throw error
    }
    if presentation == .visible { contexts[id]?.window.makeKeyAndOrderFront(nil) }
    return id
  }

  /// Creates a saved browser window on the requested Space when Settings has no native window.
  @discardableResult
  func createWorkspaceWindowForSettingsSpace(_ spaceID: UUID) throws -> UUID {
    guard workspace.workspace.catalog.spaces.contains(where: { $0.id == spaceID }) else {
      throw WorkspaceError.invalidState
    }
    let id = try workspace.newWindow(from: workspace.workspace.focusedWindowID)
    guard let store = workspace.stores[id] else {
      try? workspace.removeWindow(id)
      throw WorkspaceError.invalidState
    }
    store.perform(.space(spaceID))
    return id
  }

  func openSpaceFromSettings(_ spaceID: UUID) {
    let context: NativeBrowserContext
    if let existing = contexts.values.first(where: {
      $0.store.session.spaces.contains { $0.id == spaceID }
    }) {
      context = existing
    } else {
      do {
        let id = try createWorkspaceWindowForSettingsSpace(spaceID)
        do {
          try attach(id, source: nil)
        } catch {
          try? workspace.removeWindow(id)
          if events.runtime.window(forID: id.uuidString) != nil {
            events.runtime.closeWindowID(id.uuidString)
          }
          throw error
        }
        guard let created = contexts[id] else { throw WorkspaceError.invalidState }
        context = created
      } catch {
        report(error)
        return
      }
    }
    context.store.perform(.space(spaceID))
    if Self.settingsSpaceSelectionShouldPresentWindow(in: presentation) {
      context.window.makeKeyAndOrderFront(nil)
    }
  }

  func canPerform(_ command: BrowserMenuCommand) -> Bool {
    guard !events.runtime.isQuitting else { return false }
    if command == .quit { return true }
    if command == .reopenClosedWindow { return lastClosedWindowSnapshot != nil }
    if command == .bringAllToFront { return true }
    if command == .openFile { return true }
    if command == .newWindow { return true }
    if command == .newMiniWindow {
      return privateHost?.hasActiveWindow != true && miniWindowTarget != nil
    }
    if command == .nextWindow || command == .previousWindow {
      return Self.cycledWindow(
        from: keyWindow(), among: NSApp.windows.filter(\.isVisible),
        backwards: command == .previousWindow) != nil
    }
    if command == .checkForUpdates { return canCheckForUpdates }
    if command == .newPrivateWindow {
      return privateWindowSourceProfileID() != nil
    }
    if privateHost?.hasActiveWindow == true {
      if command == .reopenClosed {
        let owner = privateHost?.activeOwner
        let canReopenWindow =
          lastClosedWindowSnapshot != nil
          && owner?.store.sheet == nil && owner?.window.attachedSheet == nil
        return Self.reopenClosedShortcutCommand(
          canReopenTab: privateHost?.canPerform(.reopenClosed) == true,
          hasClosedWindow: canReopenWindow) != nil
      }
      return privateHost?.canPerform(command) == true
    }
    if command == .settings {
      guard let context = activeContext else { return true }
      return context.store.sheet == nil && context.window.attachedSheet == nil
    }
    if let settingsWindow = settingsController?.window, keyWindow() === settingsWindow {
      return command == .closeTab || command == .closeWindow
    }
    guard let context = activeContext else {
      if command == .reopenClosed {
        return Self.reopenClosedShortcutCommand(
          canReopenTab: false, hasClosedWindow: lastClosedWindowSnapshot != nil) != nil
      }
      return false
    }
    if command == .reopenClosed {
      let canReopenWindow =
        lastClosedWindowSnapshot != nil
        && context.store.sheet == nil && context.window.attachedSheet == nil
      return Self.reopenClosedShortcutCommand(
        canReopenTab: windowCanPerform(command, in: context, afterLauncher: false),
        hasClosedWindow: canReopenWindow) != nil
    }
    return windowCanPerform(command, in: context, afterLauncher: false)
  }

  func privateWindowSourceProfileID() -> String? {
    if let active = privateHost?.activeOwner?.sourceProfileID { return active }
    if let active = activeContext?.store.session.selectedSpace.profileID {
      return active.uuidString
    }
    let saved = workspace.workspace.focusedWindowID.flatMap { workspace.workspace.window($0) }
    return
      (saved?.session.selectedSpace.profileID
      ?? workspace.workspace.catalog.spaces.first?.profileID)?.uuidString
  }

  /// Enablement inside one browser window. `afterLauncher` asks whether a launcher Action may
  /// run once the launcher closes, so the open launcher itself does not disable it.
  private func windowCanPerform(
    _ command: BrowserMenuCommand, in context: NativeBrowserContext, afterLauncher: Bool
  ) -> Bool {
    let store = context.store
    guard store.sheet == nil, context.window.attachedSheet == nil else { return false }
    switch command {
    case .back:
      guard let id = store.session.selectedPage?.tab.id else { return false }
      return context.engine.pages[id]?.canGoBack == true
    case .forward:
      guard let id = store.session.selectedPage?.tab.id else { return false }
      return context.engine.pages[id]?.canGoForward == true
    case .closeTab:
      return !store.commandIsOpen || store.session.selectedPage == nil
    case .find: return store.canFindCurrentPage
    case .findNext, .findPrevious: return store.pageFind?.canMove == true
    case .reload, .hardReload:
      return afterLauncher ? store.currentPageAllowsReload : store.canReloadCurrentPage
    case .zoomIn, .zoomOut, .actualSize:
      return store.session.selectedPage != nil
    case .developerTools, .chromiumDeveloperTools:
      return context.engine.siteControlTarget != nil && (afterLauncher || !store.commandIsOpen)
    case .inspector:
      return context.engine.siteControlTarget != nil && (afterLauncher || !store.commandIsOpen)
    case .inspectorCopy:
      guard let target = context.engine.siteControlTarget else { return false }
      return context.engine.inspectors[target.tabID]?.aiCopy.canCopy == true
    case .inspectorSource, .inspectorAgentCopy:
      guard let target = context.engine.siteControlTarget else { return false }
      guard let inspector = context.engine.inspectors[target.tabID] else { return false }
      return inspector.aiCopy.canCopy && !inspector.sourceActions.busy
    case .splitView: return store.canSplitSelectedTab
    case .nextSpace, .previousSpace: return store.canCycleSpace
    case .reopenClosed: return store.canReopenClosedTab
    case .bookmarkPage: return store.canBookmarkCurrentPage
    case .sharePage: return Self.shareURL(for: store) != nil
    case .pasteAndGo:
      return Self.pasteAndGoDestination(for: store) != nil
    case .print:
      return Self.printCommandIsAvailable(
        hasSelectedPage: store.session.selectedPage != nil,
        commandIsOpen: store.commandIsOpen,
        hasNativePrint: (context.engine.runtime as? ARCShaarRuntime)?.supportsNativePrint() == true
      )
    case .addFavorite:
      return afterLauncher ? store.currentPageAllowsFavorite : store.canFavoriteCurrentPage
    default: return true
    }
  }

  /// Commands that act on the app rather than one window and need no window to be enabled.
  private static let appCommands: Set<BrowserMenuCommand> = [
    .openFile, .newWindow, .newPrivateWindow, .newMiniWindow, .reopenClosedWindow, .bringAllToFront,
    .nextWindow, .previousWindow, .quit,
  ]

  func perform(_ command: BrowserMenuCommand) {
    guard canPerform(command) else { return }
    if command == .reopenClosed, activeBrowserStore?.canReopenClosedTab != true {
      _ = performAppCommand(.reopenClosedWindow)
      return
    }
    if performAppCommand(command) { return }
    if privateHost?.hasActiveWindow == true {
      privateHost?.perform(command)
      return
    }
    if command == .settings {
      settingsController?.show(for: activeContext?.store.session.selectedSpace.profileID)
      return
    }
    if command == .clearHistory {
      let profileID =
        activeContext?.store.session.selectedSpace.profileID
        ?? privateWindowSourceProfileID().flatMap(UUID.init(uuidString:))
      settingsController?.showClearHistory(
        for: profileID)
      return
    }
    if let settingsWindow = settingsController?.window, keyWindow() === settingsWindow {
      settingsController?.close()
      return
    }
    guard let context = activeContext else { return }
    perform(command, in: context)
  }

  /// Runs app-wide commands; returns false for commands that belong to a window.
  private func performAppCommand(_ command: BrowserMenuCommand) -> Bool {
    switch command {
    case .quit: quit()
    case .newWindow:
      do { _ = try newWindow(from: activeContext?.id ?? workspace.workspace.focusedWindowID) }
      catch { report(error) }
    case .reopenClosedWindow:
      guard let closedWindow = lastClosedWindowSnapshot else { return true }
      do {
        _ = try restoreWindow(closedWindow)
        lastClosedWindowSnapshot = nil
      } catch { report(error) }
    case .bringAllToFront:
      let windows = NSApp.windows.filter(\.isVisible)
      Self.bringAllWindowsToFront(
        windows, keyWindow: NSApp.keyWindow,
        orderFront: { $0.orderFront(nil) }, makeKey: { $0.makeKey() })
    case .openFile:
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = true
      guard panel.runModal() == .OK else { break }
      Self.routeOpenFileSelection(panel.urls, open: openReadableFileURL)
    case .newMiniWindow: openMiniWindow(url: nil)
    case .newPrivateWindow:
      do { try privateHost?.openWindow() } catch { report(error) }
    case .nextWindow, .previousWindow:
      if let target = Self.cycledWindow(
        from: keyWindow(), among: NSApp.windows.filter(\.isVisible),
        backwards: command == .previousWindow)
      {
        target.makeKeyAndOrderFront(nil)
      }
    case .checkForUpdates: updater?.checkForUpdates()
    default: return false
    }
    return true
  }

  static func cycledWindow(
    from current: NSWindow?, among windows: [NSWindow], backwards: Bool,
    activate: ((NSWindow) -> Void)? = nil
  ) -> NSWindow? {
    let candidates = windows.filter(\.canBecomeKey)
    guard candidates.count > 1, let current,
      let index = candidates.firstIndex(where: { $0 === current })
    else { return nil }
    let direction = backwards ? -1 : 1
    let next = (index + direction + candidates.count) % candidates.count
    let target = candidates[next]
    activate?(target)
    return target
  }

  static func bringAllWindowsToFront(
    _ windows: [NSWindow], keyWindow: NSWindow?,
    orderFront: (NSWindow) -> Void, makeKey: (NSWindow) -> Void
  ) {
    windows.forEach(orderFront)
    if let keyWindow, windows.contains(where: { $0 === keyWindow }) { makeKey(keyWindow) }
  }

  private func restoreWindow(_ closedWindow: WorkspaceWindow) throws -> UUID {
    guard started, !events.runtime.isQuitting else { throw WorkspaceError.invalidState }
    let source = activeContext
    let id = try workspace.restoreWindow(closedWindow, from: source?.id)
    do {
      try attach(id, source: source?.window.frame)
    } catch {
      try? workspace.removeWindow(id)
      if events.runtime.window(forID: id.uuidString) != nil {
        events.runtime.closeWindowID(id.uuidString)
      }
      throw error
    }
    if presentation == .visible { contexts[id]?.window.makeKeyAndOrderFront(nil) }
    return id
  }

  /// Development bundles carry no update feed, so their updater never exists.
  private var canCheckForUpdates: Bool { updater?.canCheckForUpdates == true }

  private func quit() {
    if UserDefaults.standard.bool(forKey: "settingsWarnBeforeQuit") && presentation == .visible {
      let alert = NSAlert()
      alert.messageText = ShellL10n.format("Quit %@?", arguments: [.string(ProductIdentity.name)])
      alert.informativeText = ShellL10n.string("Your windows and tabs will be saved.")
      alert.addButton(withTitle: ShellL10n.string("Quit"))
      alert.addButton(withTitle: ShellL10n.string("Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    events.quit()
  }

  func restartForLanguageChange() -> String? {
    do {
      try BrowserRestart.prepare(workspace: workspace, flushGeometry: flushGeometry)
      restartRequested = true
      events.quit()
      return nil
    } catch {
      return SettingsL10n.string("Your tabs could not be saved. Shaar has not restarted.")
    }
  }

  // MARK: Launcher Actions

  /// Launcher Actions the window can run now, titled as its menu would show them.
  func launcherCommands(inWindow id: UUID) -> [LauncherCommand] {
    guard let context = contexts[id] else { return [] }
    return LauncherCommands.catalog.compactMap { item in
      guard let command = BrowserMenuCommand(rawValue: item.id),
        canPerformLauncherCommand(command, in: context)
      else { return nil }
      guard command == .closeTab else { return item }
      return item.retitled(Self.closeTabTitle(for: context.store))
    }
  }

  /// Runs a launcher Action in the window that owns the launcher, whichever window is key now.
  func performLauncherCommand(_ name: String, inWindow id: UUID) {
    guard let command = BrowserMenuCommand(rawValue: name), let context = contexts[id],
      canPerformLauncherCommand(command, in: context)
    else { return }
    if performAppCommand(command) { return }
    if command == .settings {
      settingsController?.show(for: context.store.session.selectedSpace.profileID)
      return
    }
    perform(command, in: context)
  }

  private func canPerformLauncherCommand(
    _ command: BrowserMenuCommand, in context: NativeBrowserContext
  ) -> Bool {
    guard !events.runtime.isQuitting, !context.engine.isClosed else { return false }
    if Self.appCommands.contains(command) { return true }
    if command == .checkForUpdates { return canCheckForUpdates }
    return windowCanPerform(command, in: context, afterLauncher: true)
  }

  /// Close Tab closes the window when no page is selected, and says so.
  static func closeTabTitle(for store: BrowserStore) -> String {
    ShellL10n.string(store.session.selectedPage == nil ? "Close window" : "Close tab")
  }

  static func shareURL(for store: BrowserStore?) -> URL? {
    guard let url = store?.session.selectedPage?.tab.url,
      NavigationInput.isWebURL(url)
    else { return nil }
    return CleanLink.clean(url)
  }

  static func showRecentlyClosed(in store: BrowserStore) {
    store.showRecentlyClosed()
  }

  static func pasteAndGoDestination(for store: BrowserStore) -> URL? {
    PasteAndGoCommand.destination(
      in: .general,
      searchEngine: store.preferences.searchEngine(for: store.session.selectedSpace.profileID))
  }

  static func showAllHistory(in store: BrowserStore) {
    store.showLibrary(.history)
  }

  static func presentSharePicker(for url: URL, in window: NSWindow) {
    guard let contentView = window.contentView else { return }
    let picker = NSSharingServicePicker(items: [url])
    picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
  }

  static func bookmarkCurrentPage(in store: BrowserStore) {
    store.bookmarkCurrentPage()
  }

  static func showBookmarks(in store: BrowserStore) {
    store.showLibrary(.bookmarks)
  }

  private func perform(_ command: BrowserMenuCommand, in context: NativeBrowserContext) {
    let store = context.store
    switch command {
    case .newTab:
      store.showCommand()
      store.commandEditsCurrentURL = false
    case .search:
      store.showCommand()
      store.commandEditsCurrentURL = true
      store.commandQuery = store.session.selectedPage?.tab.url.absoluteString ?? ""
    case .newSpace: store.spaceEditor = .create
    case .editSpace: store.spaceEditor = .edit(store.session.selectedSpaceID)
    case .createFolder:
      store.showFolderEditor(.create(spaceID: store.session.selectedSpaceID, parentID: nil))
    case .closeTab:
      if store.session.selectedPage != nil {
        store.closeCurrentPage()
      } else {
        requestCloseWindow(context)
      }
    case .back:
      let id = store.session.selectedPage?.tab.id
      _ = Self.routeBack(
        tabID: id, canGoBack: id.flatMap { context.engine.pages[$0]?.canGoBack } == true
      ) { context.engine.runtime.goBack(inTabID: $0) }
    case .forward:
      let id = store.session.selectedPage?.tab.id
      _ = Self.routeForward(
        tabID: id, canGoForward: id.flatMap { context.engine.pages[$0]?.canGoForward } == true
      ) { context.engine.runtime.goForward(inTabID: $0) }
    case .addFavorite: _ = store.addCurrentPageAsFavorite()
    case .closeWindow: requestCloseWindow(context)
    case .reopenClosed: store.reopenLastClosedTab()
    case .recentlyClosed: store.showRecentlyClosed()
    case .bookmarkPage: Self.bookmarkCurrentPage(in: store)
    case .bookmarks: Self.showBookmarks(in: store)
    case .history: Self.showAllHistory(in: store)
    case .clearHistory: break  // Routed through the settings controller above.
    case .downloads: store.showDownloads()
    case .sharePage:
      if let url = Self.shareURL(for: store) {
        Self.presentSharePicker(for: url, in: context.window)
      }
    case .pasteAndGo:
      _ = PasteAndGoCommand.route(
        in: .general, store: store,
        searchEngine: store.preferences.searchEngine(for: store.session.selectedSpace.profileID),
        navigate: context.engine.navigateCurrentPage(to:))
    case .print:
      guard let page = store.session.selectedPage,
        let runtime = context.engine.runtime as? ARCShaarRuntime,
        runtime.printTabID(
          page.tab.id.uuidString, windowID: context.nativeID,
          profileID: store.session.selectedSpace.profileID.uuidString)
      else {
        report(
          NSError(
            domain: "com.arcusis.browser.print", code: 1,
            userInfo: [NSLocalizedDescriptionKey: ShellL10n.string("Could not open print panel")]))
        return
      }
    case .find: store.showPageFind()
    case .findNext: store.movePageFind(forward: true)
    case .findPrevious: store.movePageFind(forward: false)
    case .sidebar: store.sidebarIsVisible.toggle()
    case .nextSpace: store.cycleSpace(by: 1)
    case .previousSpace: store.cycleSpace(by: -1)
    case .reload: store.reloadCurrentPage()
    case .hardReload: store.reloadCurrentPage(.bypassingCache)
    case .zoomIn, .zoomOut, .actualSize:
      _ = PageZoomMenuRouter.route(command, focusedTabID: store.session.selectedPage?.tab.id) {
        action, tabID in context.engine.performPageZoomAction(action, tabID: tabID)
      }
    case .developerTools: context.engine.toggleChromiumDeveloperTools()
    case .chromiumDeveloperTools: context.engine.toggleChromiumDeveloperTools()
    case .inspector: context.engine.toggleInspector()
    case .inspectorCopy:
      if let target = context.engine.siteControlTarget,
        let inspector = context.engine.inspectors[target.tabID]
      {
        Task { await inspector.aiCopy.copyElement() }
      }
    case .inspectorSource:
      if let target = context.engine.siteControlTarget,
        let inspector = context.engine.inspectors[target.tabID]
      {
        Task { await inspector.sourceActions.open() }
      }
    case .inspectorAgentCopy:
      if let target = context.engine.siteControlTarget,
        let inspector = context.engine.inspectors[target.tabID]
      {
        Task { await inspector.sourceActions.copyForAgent() }
      }
    case .splitView: store.splitSelectedTab()
    case .extensions: context.engine.showExtensionList()
    case .help:
      if let url = URL(string: "https://github.com/arcusis/shaar") { store.perform(.open(url)) }
    case .minimizeWindow: context.window.performMiniaturize(nil)
    case .zoomWindow: context.window.zoom(nil)
    case .bringAllToFront:
      for browser in contexts.values { browser.window.orderFront(nil) }
      context.window.makeKeyAndOrderFront(nil)
    case .newWindow, .newPrivateWindow, .newMiniWindow, .reopenClosedWindow, .nextWindow, .previousWindow,
      .openFile, .settings, .quit, .checkForUpdates:
      break
    case .fullScreen: context.window.toggleFullScreen(nil)
    }
  }

  func flushGeometry() {
    for context in contexts.values { saveGeometry(context) }
  }

  func detach() {
    if fileOpenHandlerInstalled {
      NSAppleEventManager.shared().removeEventHandler(
        forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
      fileOpenHandlerInstalled = false
    }
    if reopenHandlerInstalled {
      NSAppleEventManager.shared().removeEventHandler(
        forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
      reopenHandlerInstalled = false
    }
    events.onQuitRequested = nil
    events.onQuitCancelled = nil
    if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    shortcutMonitor = nil
    privateHost?.detach()
    privateHost = nil
    profileOnboarding?.model.cancel()
    for flow in Array(accountSignIns.values) { flow.cancel() }
    profileOnboarding?.close()
    profileOnboarding = nil
    events.onWindowRequest = nil
    events.onWindowShowRequest = nil
    events.onDevToolsOpenURLRequest = nil
    events.onTabClosed = nil
    events.onNewTabWillAdopt = nil
    for context in contexts.values {
      stopObserving(context)
      context.engine.onClosed = nil
    }
    guard let menu, let application = NSApp else { return }
    if application.mainMenu === menu { application.mainMenu = previousMenu }
    if application.servicesMenu
      === menu.items.first?.submenu?.items.first(where: {
        $0.submenu?.identifier?.rawValue == "Services"
          || $0.submenu?.title == ShellL10n.string("Services")
      })?.submenu
    {
      application.servicesMenu = previousServicesMenu
    }
    if application.windowsMenu
      === menu.items.first(where: {
        $0.submenu?.identifier?.rawValue == "Window"
          || $0.submenu?.title == ShellL10n.string("Window")
      })?.submenu
    {
      application.windowsMenu = previousWindowsMenu
    }
    if application.helpMenu
      === menu.items.first(where: {
        $0.submenu?.identifier?.rawValue == "Help"
          || $0.submenu?.title == ShellL10n.string("Help")
      })?.submenu
    {
      application.helpMenu = previousHelpMenu
    }
  }

  /// Connect or disconnect a provider account of a saved profile from Settings.
  private func runSavedProfileSignIn(
    _ profileID: UUID, provider: AccountProvider, purpose: ProfileAccountSignIn.Purpose,
    option: AccountSignInOption? = nil
  ) {
    guard
      let profile = workspace.workspace.catalog.profiles.first(where: { $0.id == profileID })
    else { return }
    // Apple offers no public web logout URL. Disconnect the primary link; iCloud retains its
    // own Sign Out control rather than pretending a visit to its home page clears cookies.
    if purpose == .signOut, provider == .apple {
      preferences.removeAccount(provider, for: profileID)
      return
    }
    runAccountSignIn(profile, provider: provider, purpose: purpose, option: option) {
      [weak self] account in
      guard let self else { return }
      switch (purpose, account) {
      case (.signIn, let account?): self.preferences.setAccount(account, for: profileID)
      case (.signOut, _): self.preferences.removeAccount(provider, for: profileID)
      default: break
      }
    }
  }

  /// Runs sign-in or sign-out inside the profile's own engine storage. The profile need not be
  /// saved yet, so onboarding can connect accounts before it creates the profile.
  private func runAccountSignIn(
    _ profile: BrowserProfile, provider: AccountProvider, purpose: ProfileAccountSignIn.Purpose,
    option: AccountSignInOption? = nil,
    completion: @escaping (ConnectedAccount?) -> Void
  ) {
    do {
      let flow = try ProfileAccountSignIn(
        events: events, profile: profile, provider: provider, purpose: purpose,
        visible: presentation == .visible, option: option)
      let id = flow.engine.windowID
      accountSignIns[id] = flow
      flow.onFinished = { [weak self] account in
        self?.accountSignIns[id] = nil
        completion(account)
      }
    } catch {
      report(error)
      completion(nil)
    }
  }

  /// The single entry point for New Profile, from Settings or from a Space's profile menu. A
  /// Space that asks gets the new profile once it is created.
  func presentNewProfile(assigningSpace spaceID: UUID? = nil) {
    if let profileOnboarding {
      if presentation == .visible { profileOnboarding.show() }
      return
    }
    let model = ProfileOnboardingModel(spaceID: spaceID, actions: profileOnboardingActions())
    let onboarding = ProfileOnboardingWindow(model: model)
    profileOnboarding = onboarding
    if presentation == .visible { onboarding.show() }
  }

  private func profileOnboardingActions() -> ProfileOnboardingActions {
    ProfileOnboardingActions(
      connect: { [weak self] profile, option, completion in
        self?.runAccountSignIn(
          profile, provider: option.provider, purpose: .signIn, option: option,
          completion: completion)
      },
      stopConnecting: { [weak self] in
        guard let profileID = self?.profileOnboarding?.model.profileID else { return }
        self?.cancelAccountSignIns(for: profileID)
      },
      create: { [workspace, preferences] draft in
        try draft.create(in: workspace, preferences: preferences)
      },
      close: { [weak self] outcome in self?.profileOnboardingClosed(outcome) })
  }

  private func cancelAccountSignIns(for profileID: UUID) {
    for flow in Array(accountSignIns.values) where flow.profileID == profileID { flow.cancel() }
  }

  private func profileOnboardingClosed(_ outcome: ProfileOnboardingModel.Outcome) {
    profileOnboarding?.close()
    profileOnboarding = nil
    if case .created(let id) = outcome { settingsController?.selectProfile(id) }
  }

  /// Install after Chromium starts so Dock reopen cannot create an unmanaged blank window.
  func installReopenHandler() {
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleReopen(_:reply:)),
      forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    reopenHandlerInstalled = true
  }

  @objc func handleReopen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard started, !startupFailed, !events.runtime.isQuitting else { return }
    do {
      let context: NativeBrowserContext
      if let existing = workspace.workspace.focusedWindowID.flatMap({ contexts[$0] })
        ?? contexts.values.first
      {
        context = existing
      } else {
        let id = try newWindow()
        guard let created = contexts[id] else { throw WorkspaceError.invalidState }
        context = created
        // Ignore the retired new-window preference when recovering the main window.
        context.store.sidebarIsVisible = true
      }
      if presentation == .visible {
        if context.window.isMiniaturized { context.window.deminiaturize(nil) }
        context.window.makeKeyAndOrderFront(nil)
      }
    } catch { report(error) }
  }

  @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = IncomingURLPolicy.url(from: text)
    else { return }
    if !started {
      pendingURLs.append(url)
      return
    }
    openExternalURL(url)
  }

  @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    for url in IncomingFileOpenPolicy.fileURLs(
      from: event.paramDescriptor(forKeyword: keyDirectObject))
    {
      if started {
        openFileURL(url)
      } else {
        pendingFileURLs.append(url)
      }
    }
  }

  private func openFileURL(_ url: URL) {
    Self.routeOpenFileSelection([url], open: openReadableFileURL)
  }

  static func routeOpenFileSelection(_ urls: [URL], open: (URL) -> Void) {
    for url in urls {
      guard let fileURL = IncomingFileOpenPolicy.readableFileURL(url) else { continue }
      open(fileURL)
    }
  }

  private func openReadableFileURL(_ fileURL: URL) {
    let context: NativeBrowserContext
    if let existing = activeContext ?? workspace.workspace.focusedWindowID.flatMap({ contexts[$0] })
      ?? contexts.values.first
    {
      context = existing
    } else {
      do {
        let id = try newWindow()
        guard let created = contexts[id] else { throw WorkspaceError.invalidState }
        context = created
      } catch {
        report(error)
        return
      }
    }
    context.store.perform(.open(fileURL))
    if presentation == .visible { context.window.makeKeyAndOrderFront(nil) }
  }

  private func openExternalURL(_ url: URL) {
    guard
      let route = MiniLinkRoute.route(
        url, inMainWindow: UserDefaults.standard.bool(forKey: "externalLinksInMainWindow"))
    else { return }
    let context: NativeBrowserContext
    if let existing = activeContext ?? workspace.workspace.focusedWindowID.flatMap({ contexts[$0] })
      ?? contexts.values.first
    {
      context = existing
    } else {
      do {
        let id = try newWindow()
        guard let created = contexts[id] else { throw WorkspaceError.invalidState }
        context = created
      } catch {
        report(error)
        return
      }
    }
    switch route {
    case .main(let url):
      context.store.perform(.open(url))
      if presentation == .visible { context.window.makeKeyAndOrderFront(nil) }
    case .mini(let url):
      openMiniWindow(url: url, context: context)
    }
  }

  @discardableResult
  private func openMiniWindow(
    url: URL?, context: NativeBrowserContext? = nil, destination: UUID? = nil
  ) -> Bool {
    guard let target = context ?? miniWindowTarget else { return false }
    do {
      let mini = try MiniBrowserController(
        events: events, target: target.store, targetWindow: target.window, url: url,
        destination: destination)
      let id = mini.engine.windowID
      miniWindows[id] = mini
      mini.onClosed = { [weak self] in self?.miniWindows[id] = nil }
      mini.onProfileChange = { [weak self, weak target] destination, url in
        guard let self, let target else { return false }
        return self.openMiniWindow(url: url, context: target, destination: destination)
      }
      return true
    } catch {
      report(error)
      return false
    }
  }

  private func attach(
    _ id: UUID, source: NSRect?, reconcile: Bool = true, nativeWindowID: String? = nil
  ) throws {
    guard let store = workspace.stores[id], let record = workspace.workspace.window(id) else {
      throw WorkspaceError.unknownWindow
    }
    store.usePreferences(preferences)
    let runtime = events.runtime
    let nativeID: String
    var creationGuard: NativeWindowCreationGuard?
    if usesPrimaryWindow && !claimedPrimary && runtime.window != nil {
      claimedPrimary = true
      nativeID = runtime.primaryWindowID
    } else {
      nativeID = nativeWindowID ?? id.uuidString
      try runtime.createWindowID(nativeID)
      creationGuard = NativeWindowCreationGuard { _ = runtime.closeWindowID(nativeID) }
    }
    defer { creationGuard?.closeIfUnowned() }
    guard runtime.isWindowOpenID(nativeID),
      let window = runtime.window(forID: nativeID),
      let content = runtime.hostView(forWindowID: nativeID)
    else {
      throw WorkspaceError.invalidState
    }
    let engine = try BrowserEngine(
      events: events, windowID: nativeID, store: store,
      presentsNativePanels: presentation == .visible,
      lazyPinnedTabs: true, downloadDirectoryApplier: downloadDirectoryApplier)
    let hosting = NSHostingView(rootView: BrowserWindow(store: store))
    window.title = ProductIdentity.name
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.isMovable = true
    let frame = NativeWindowPlacement.frame(
      saved: record.geometry, source: source, screens: screens())
    window.minSize = NSSize(width: min(760, frame.width), height: min(520, frame.height))
    window.setFrame(frame, display: false)
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    // Chromium's embed container can exclude the native titlebar. Install the
    // safe strip in the window frame so its geometry includes that top edge.
    let titlebarHost = window.contentView?.superview ?? content
    let titlebarDragView = WindowDragRegion.makeTitlebarDragView(
      window: window, contentView: titlebarHost,
      isRightToLeft: BrowserLanguage.currentLaunchLanguage.isRightToLeft,
      trailingAccessoryWidth: BrowserLanguage.currentLaunchLanguage.isRightToLeft
        ? BrowserChromeLayout.titlebarToggleLeading + 28 : 0)
    titlebarHost.addSubview(titlebarDragView, positioned: .above, relativeTo: nil)
    let context = NativeBrowserContext(
      id: id, nativeID: nativeID, window: window, store: store, engine: engine, hosting: hosting,
      contentView: content, titlebarDragView: titlebarDragView)
    contexts[id] = context
    creationGuard?.transferToOwner()
    store.launcherActions = LauncherActions(
      available: { [weak self] in self?.launcherCommands(inWindow: id) ?? [] },
      run: { [weak self] name in self?.performLauncherCommand(name, inWindow: id) })
    store.onNewProfile = { [weak self] spaceID in self?.presentNewProfile(assigningSpace: spaceID) }
    engine.onClosed = { [weak self] quitting in self?.closed(id, quitting: quitting) }
    engine.onNativeWindowLost = { [weak self] in self?.recoverLostWindow(id) }
    observe(context)
    if reconcile { engine.reconcile() }
  }

  private func requestedWindow(profile: String, type: String, userGesture: Bool) -> String? {
    guard userGesture else { return nil }
    if let requestedProfileID = UUID(uuidString: profile),
      let flow = accountSignIns.values.first(where: { $0.profileID == requestedProfileID })
    {
      return flow.requestedWindow(type: type)
    }
    guard started, !events.runtime.isQuitting, ["normal", "popup", "app"].contains(type),
      let profileID = UUID(uuidString: profile),
      let destination = workspace.workspace.catalog.spaces.first(where: {
        $0.profileID == profileID
      })
    else { return nil }
    let source = activeContext.flatMap {
      $0.store.session.selectedSpace.profileID == profileID ? $0 : nil
    }
    var created: UUID?
    do {
      let previousFocus = workspace.workspace.focusedWindowID
      let id = try workspace.newWindow(from: source?.id)
      created = id
      if let previousFocus { try workspace.focusWindow(previousFocus) }
      let spaceID = source?.store.session.selectedSpaceID ?? destination.id
      workspace.stores[id]?.perform(.space(spaceID))
      // Do not prepare/open any profile here: Chromium attaches its new Browser
      // to this empty host only after the synchronous factory returns.
      try attach(id, source: source?.window.frame, reconcile: false)
      let context = contexts[id]!
      engineRequestedWindows.insert(context.nativeID)
      authoredPopupWindows.insert(context.nativeID)
      DispatchQueue.main.async { [weak self, weak context] in
        guard let self, let context, self.contexts[id] === context, !context.engine.isClosed,
          !self.events.runtime.isQuitting
        else {
          return
        }
        context.engine.reconcile()
      }
      return context.nativeID
    } catch {
      if let created {
        try? workspace.removeWindow(created)
        events.runtime.closeWindowID(created.uuidString)
      }
      report(error)
      return nil
    }
  }

  private func openDevToolsRequestedURL(_ payload: [String: Any]) {
    guard started, !events.runtime.isQuitting,
      let request = DevToolsOpenURLRequest(payload)
    else { return }
    if request.contextID != nil {
      privateHost?.openDevToolsRequestedURL(request)
      return
    }
    guard let context = contexts.values.first(where: { $0.nativeID == request.windowID }),
      !context.engine.isClosed, context.engine.liveTabs.contains(request.tabID),
      events.runtime.windowID(forTabID: request.tabID.uuidString) == request.windowID
    else { return }
    _ = context.store.openDevToolsRequestedTab(
      request.url, sourceTabID: request.tabID, profileID: request.profileID)
  }

  private func closeEmptyAuthoredPopup(windowID: String) {
    guard authoredPopupWindows.contains(windowID),
      let context = contexts.values.first(where: { $0.nativeID == windowID }),
      context.engine.liveTabs.isEmpty
    else { return }
    authoredPopupWindows.remove(windowID)
    requestCloseWindow(context)
  }

  private func showRequestedWindow(_ nativeID: String, active: Bool) {
    // The engine can request visibility during insertion. Present only once its
    // notification has unwound and the application has adopted the page.
    DispatchQueue.main.async { [weak self] in
      if let flow = self?.accountSignIns.values.first(where: { $0.ownsWindow(nativeID) }) {
        flow.showWindow(nativeID, active: active)
        return
      }
      guard let self, self.presentation == .visible,
        !self.events.runtime.isQuitting,
        let context = self.contexts.values.first(where: { $0.nativeID == nativeID }),
        !context.engine.isClosed
      else { return }
      if active { context.window.makeKeyAndOrderFront(nil) } else { context.window.orderFront(nil) }
    }
  }

  private func prepareNewTab(_ tab: String, profile: String, opener: String?) {
    guard let nativeID = events.runtime.windowID(forTabID: tab),
      engineRequestedWindows.remove(nativeID) != nil
    else { return }
    guard let profileID = UUID(uuidString: profile),
      let opener, let openerID = UUID(uuidString: opener),
      let sourceNativeID = events.runtime.windowID(forTabID: opener),
      let source = contexts.values.first(where: { $0.nativeID == sourceNativeID }),
      source.store.session.profileID(forTabID: openerID) == profileID,
      let destination = contexts.values.first(where: { $0.nativeID == nativeID })
    else { return }
    guard
      let spaceID = Self.openerSpaceID(
        in: source.store.session, openerID: openerID, profileID: profileID)
    else { return }
    destination.store.perform(.space(spaceID))
  }

  static func openerSpaceID(
    in session: BrowserSession, openerID: UUID, profileID: UUID
  ) -> UUID? {
    guard session.profileID(forTabID: openerID) == profileID else { return nil }
    if let ordinarySpace = session.spaces.first(where: {
      $0.profileID == profileID && $0.tabs.contains { $0.id == openerID }
    }) {
      return ordinarySpace.id
    }
    guard
      let favoriteID = session.favoritePages.first(where: {
        $0.tab.id == openerID
      })?.favoriteID
    else { return nil }
    return session.spaces.first(where: {
      $0.id == session.selectedSpaceID && $0.profileID == profileID
    })?.id ?? session.spaces.first(where: {
      $0.profileID == profileID && $0.selectedFavoriteID == favoriteID
    })?.id ?? session.spaces.first(where: { $0.profileID == profileID })?.id
  }

  private func observe(_ context: NativeBrowserContext) {
    let center = NotificationCenter.default
    context.observers.append(
      center.addObserver(
        forName: NSWindow.willCloseNotification, object: context.window, queue: .main
      ) { [weak self, weak context] _ in
        MainActor.assumeIsolated {
          guard let self, let context else { return }
          self.appClosingWindows.insert(context.id)
          self.events.windowClosed(context.nativeID, quitting: false)
        }
      })
    context.observers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: context.window, queue: .main
      ) {
        [weak self, weak context] _ in
        MainActor.assumeIsolated {
          guard let self, let context else { return }
          do { try self.workspace.focusWindow(context.id) } catch { self.report(error) }
          context.engine.handOffPictureInPicture()
        }
      })
    for name in [
      NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ] {
      context.observers.append(
        center.addObserver(forName: name, object: context.window, queue: .main) {
          [weak context] _ in
          MainActor.assumeIsolated { context?.engine.handOffPictureInPicture() }
        })
    }
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      context.observers.append(
        center.addObserver(forName: name, object: context.window, queue: .main) {
          [weak self, weak context] _ in
          MainActor.assumeIsolated {
            guard let self, let context else { return }
            WindowDragRegion.updateTitlebarDragView(
              context.titlebarDragView, window: context.window,
              contentView: context.titlebarDragView.superview ?? context.contentView,
              isRightToLeft: BrowserLanguage.currentLaunchLanguage.isRightToLeft,
              trailingAccessoryWidth: BrowserLanguage.currentLaunchLanguage.isRightToLeft
                ? BrowserChromeLayout.titlebarToggleLeading + 28 : 0)
            context.geometryTask?.cancel()
            context.geometryTask = Task { [weak self, weak context] in
              do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
              if let context { self?.saveGeometry(context) }
            }
          }
        })
    }
  }

  private func saveGeometry(_ context: NativeBrowserContext) {
    context.geometryTask?.cancel()
    context.geometryTask = nil
    guard !context.window.isMiniaturized, !context.window.styleMask.contains(.fullScreen),
      workspace.workspace.window(context.id) != nil
    else { return }
    let frame = context.window.frame
    do {
      try workspace.setGeometry(
        WorkspaceWindowGeometry(
          x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), for: context.id)
    } catch { report(error) }
  }

  private func closed(_ id: UUID, quitting: Bool) {
    if !quitting, !appClosingWindows.contains(id),
      let context = contexts[id],
      let selected = context.store.session.selectedPage?.tab.id,
      context.store.rendererFailures[selected] != nil
    {
      recoverLostWindow(id)
      return
    }
    guard let context = contexts.removeValue(forKey: id) else { return }
    appClosingWindows.remove(id)
    engineRequestedWindows.remove(context.nativeID)
    authoredPopupWindows.remove(context.nativeID)
    stopObserving(context)
    saveGeometry(context)
    if !quitting {
      context.store.save()
      lastClosedWindowSnapshot = workspace.workspace.window(id)
      do { try workspace.removeWindow(id) } catch { report(error) }
    } else {
      workspace.persistSnapshot()
    }
    onClosed?(id, quitting)
  }

  private func requestCloseWindow(_ context: NativeBrowserContext) {
    appClosingWindows.insert(context.id)
    if !events.runtime.closeWindowID(context.nativeID) {
      appClosingWindows.remove(context.id)
    }
  }

  private func recoverLostWindow(_ id: UUID) {
    guard let context = contexts[id], !events.runtime.isQuitting else { return }
    let frame = context.window.frame
    context.engine.onClosed = nil
    stopObserving(context)
    context.window.orderOut(nil)
    events.runtime.retireClosedWindowID(context.nativeID)
    events.windowClosed(context.nativeID, quitting: false)
    contexts[id] = nil
    do {
      try attach(id, source: frame, nativeWindowID: UUID().uuidString)
      if presentation == .visible { contexts[id]?.window.makeKeyAndOrderFront(nil) }
    } catch {
      report(error)
    }
  }

  private func stopObserving(_ context: NativeBrowserContext) {
    context.titlebarDragView.removeFromSuperview()
    context.geometryTask?.cancel()
    context.geometryTask = nil
    for observer in context.observers { NotificationCenter.default.removeObserver(observer) }
    context.observers.removeAll()
  }

  private func report(_ error: Error) {
    let message = Self.localizedFailureNotice(for: error)
    lastError = message
    activeContext?.engine.reportNotice(message)
  }

  static func localizedFailureNotice(for _: Error) -> String {
    return ShellL10n.string("Could not complete the browser window action. Try again.")
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if let id = item.representedObject as? UUID {
      guard canPerform(.editSpace), let store = activeBrowserStore else { return false }
      item.state = store.session.selectedSpaceID == id ? .on : .off
      return store.session.spaces.contains { $0.id == id }
    }
    if item.action == #selector(copyCurrentURL(_:)) {
      return Self.copyURLMenuAvailable(
        in: activeBrowserStore, menusEnabled: canPerform(.editSpace))
    }
    guard let raw = item.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return false }
    if command == .closeTab {
      item.title =
        activeBrowserStore.map(Self.closeTabTitle(for:))
        ?? ShellL10n.string("Close window")
    }
    if command == .fullScreen,
      let window = privateHost?.activeOwner?.window ?? activeContext?.window
    {
      item.title = ShellL10n.string(
        Self.fullScreenTitle(isFullScreen: window.styleMask.contains(.fullScreen)))
    }
    return canPerform(command)
  }

  static func fullScreenTitle(isFullScreen: Bool) -> String {
    isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
  }

  static func makeMenu(target: AnyObject) -> NSMenu {
    let main = NativeBrowserMenu()
    func localizedTitle(_ title: String) -> String {
      if title == "About \(ProductIdentity.name)" {
        return ShellL10n.format("About %@", arguments: [.string(ProductIdentity.name)])
      }
      if title == "Hide \(ProductIdentity.name)" {
        return ShellL10n.format("Hide %@", arguments: [.string(ProductIdentity.name)])
      }
      if title == "Quit \(ProductIdentity.name)" {
        return ShellL10n.format("Quit %@", arguments: [.string(ProductIdentity.name)])
      }
      if title == "\(ProductIdentity.name) Support" {
        return ShellL10n.format("%@ Support", arguments: [.string(ProductIdentity.name)])
      }
      return ShellL10n.string(title)
    }
    func section(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let result = NSMenu(title: localizedTitle(title))
      result.identifier = NSUserInterfaceItemIdentifier(title)
      item.submenu = result
      main.addItem(item)
      return result
    }
    // Every shortcut comes from ShortcutCatalog so the menus and the Shortcuts pane agree.
    func add(_ command: BrowserMenuCommand, _ title: String, to menu: NSMenu) {
      let shortcut = ShortcutCatalog.shortcut(for: command)
      let item = NSMenuItem(
        title: localizedTitle(title), action: #selector(menuAction(_:)),
        keyEquivalent: shortcut?.key ?? "")
      item.identifier = NSUserInterfaceItemIdentifier(title)
      item.target = target
      item.representedObject = command.rawValue
      item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
      menu.addItem(item)
    }
    func addStandard(_ title: String, _ action: Selector, to menu: NSMenu) {
      let shortcut = ShortcutCatalog.standardShortcut(for: title)
      let item = NSMenuItem(
        title: localizedTitle(title), action: action, keyEquivalent: shortcut?.key ?? "")
      item.identifier = NSUserInterfaceItemIdentifier(title)
      item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
      menu.addItem(item)
    }
    let app = section(ProductIdentity.name)
    addStandard(
      "About \(ProductIdentity.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      to: app)
    add(.checkForUpdates, "Check for Updates…", to: app)
    app.addItem(.separator())
    let services = NSMenu(title: ShellL10n.string("Services"))
    services.identifier = NSUserInterfaceItemIdentifier("Services")
    let servicesItem = NSMenuItem(
      title: ShellL10n.string("Services"), action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    app.addItem(servicesItem)
    app.addItem(.separator())
    add(.settings, "Settings…", to: app)
    addStandard("Hide \(ProductIdentity.name)", #selector(NSApplication.hide(_:)), to: app)
    addStandard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), to: app)
    addStandard("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app)
    app.addItem(.separator())
    add(.quit, "Quit \(ProductIdentity.name)", to: app)
    let file = section("File")
    add(.newPrivateWindow, "New Private Window", to: file)
    add(.newMiniWindow, "New Mini Window", to: file)
    add(.newWindow, "New Window", to: file)
    add(.openFile, "Open File…", to: file)
    add(.newTab, "New tab", to: file)
    add(.search, CommandPanel.searchPrompt, to: file)
    add(.print, "Print…", to: file)
    add(.sharePage, "Share Page…", to: file)
    add(.downloads, "Downloads", to: file)
    add(.closeTab, "Close tab", to: file)
    add(.closeWindow, "Close window", to: file)
    let edit = section("Edit")
    for (title, action) in [
      ("Undo", "undo:"), ("Redo", "redo:"), ("Cut", "cut:"),
      ("Copy", "copy:"), ("Paste", "paste:"), ("Select All", "selectAll:"),
    ] {
      addStandard(title, NSSelectorFromString(action), to: edit)
    }
    addStandard("Paste and Match Style", NSSelectorFromString("pasteAsPlainText:"), to: edit)
    addStandard(
      "Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), to: edit)
    add(.pasteAndGo, "Paste and Go", to: edit)
    edit.addItem(.separator())
    add(.find, "Find in Page…", to: edit)
    add(.findNext, "Find Next", to: edit)
    add(.findPrevious, "Find Previous", to: edit)
    let view = section("View")
    add(.sidebar, "Toggle sidebar", to: view)
    add(.reload, "Reload", to: view)
    add(.hardReload, "Hard Reload", to: view)
    add(.zoomIn, "Zoom In", to: view)
    add(.zoomOut, "Zoom Out", to: view)
    add(.actualSize, "Actual Size", to: view)
    add(.developerTools, "Developer Tools", to: view)
    add(.inspector, "Inspect Element", to: view)
    add(.inspectorSource, "Open source", to: view)
    add(.inspectorAgentCopy, "Copy for agent", to: view)
    add(.inspectorCopy, "Copy for AI", to: view)
    add(.fullScreen, "Enter Full Screen", to: view)
    let spaces = section("Spaces")
    add(.newSpace, "New space…", to: spaces)
    add(.editSpace, "Edit current space…", to: spaces)
    add(.nextSpace, "Next space", to: spaces)
    add(.previousSpace, "Previous space", to: spaces)
    let copyURLShortcut = ShortcutCatalog.standardShortcut(for: "Copy URL")
    let copyURL = NSMenuItem(
      title: ShellL10n.string("Copy URL"), action: #selector(copyCurrentURL(_:)),
      keyEquivalent: copyURLShortcut?.key ?? "")
    copyURL.target = target
    copyURL.keyEquivalentModifierMask = copyURLShortcut?.modifiers ?? []
    spaces.addItem(copyURL)
    let tabs = section("Tabs")
    add(.splitView, "Split View", to: tabs)
    add(.addFavorite, "Add to Favorites", to: tabs)
    add(.createFolder, "New Folder", to: tabs)
    add(.reopenClosed, "Reopen last closed tab", to: tabs)
    let history = section("History")
    add(.back, "Back", to: history)
    add(.forward, "Forward", to: history)
    add(.recentlyClosed, "Recently closed…", to: history)
    add(.reopenClosedWindow, "Reopen Last Closed Window", to: history)
    add(.history, "Show All History", to: history)
    add(.clearHistory, "Clear History…", to: history)
    let bookmarks = section("Bookmarks")
    add(.bookmarkPage, "Bookmark this page", to: bookmarks)
    add(.bookmarks, "Bookmarks…", to: bookmarks)
    let extensions = section("Extensions")
    add(.extensions, "Manage Extensions…", to: extensions)
    let window = section("Window")
    add(.nextWindow, "Next Window", to: window)
    add(.previousWindow, "Previous Window", to: window)
    add(.minimizeWindow, "Minimize", to: window)
    add(.zoomWindow, "Zoom", to: window)
    add(.bringAllToFront, "Bring All to Front", to: window)
    let help = section("Help")
    add(.help, "\(ProductIdentity.name) Support", to: help)
    return main
  }

  /// F12 and Option-Shift-Command-I open the Chromium DevTools dock.
  @discardableResult
  func performDeveloperToolsKey(_ event: NSEvent) -> Bool {
    guard let command = ShaarDevToolsShortcut.command(for: event), canPerform(command) else {
      return false
    }
    perform(command)
    return true
  }

  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return }
    (sender.target as? NativeBrowserHost)?.perform(command)
  }

  @objc private func copyCurrentURL(_ sender: NSMenuItem) {
    guard canPerform(.editSpace), let url = activeBrowserStore?.session.selectedPage?.tab.url
    else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(CleanLink.clean(url).absoluteString, forType: .string)
  }

  @objc private func selectMenuSpace(_ sender: NSMenuItem) {
    guard canPerform(.editSpace), let id = sender.representedObject as? UUID,
      let store = activeBrowserStore,
      store.session.spaces.contains(where: { $0.id == id })
    else { return }
    store.perform(.space(id))
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard
      menu.identifier?.rawValue == "Spaces"
        || menu.title == ShellL10n.string("Spaces")
    else { return }
    while let item = menu.items.first(where: { $0.representedObject is UUID || $0.tag == 91827 }) {
      menu.removeItem(item)
    }
    guard canPerform(.editSpace), let store = activeBrowserStore else { return }
    let separator = NSMenuItem.separator()
    separator.tag = 91827
    menu.addItem(separator)
    for (index, space) in store.session.spaces.enumerated() {
      let key = SpaceShortcut.key(forIndex: index).map(String.init) ?? ""
      let item = NSMenuItem(
        title: space.name, action: #selector(selectMenuSpace(_:)), keyEquivalent: key)
      item.target = self
      item.representedObject = space.id
      item.keyEquivalentModifierMask = .control
      item.state = space.id == store.session.selectedSpaceID ? .on : .off
      menu.addItem(item)
    }
  }

  private func installMenus() {
    previousMenu = NSApp.mainMenu
    previousServicesMenu = NSApp.servicesMenu
    previousWindowsMenu = NSApp.windowsMenu
    previousHelpMenu = NSApp.helpMenu
    let main = Self.makeMenu(target: self)
    menu = main
    if let spaces = main.items.first(where: { $0.submenu?.identifier?.rawValue == "Spaces" })?
      .submenu
    {
      spaces.delegate = self
      menuNeedsUpdate(spaces)
    }
    NSApp.servicesMenu =
      main.items.first?.submenu?.items.first(where: {
        $0.submenu?.identifier?.rawValue == "Services"
      })?.submenu
    NSApp.windowsMenu =
      main.items.first(where: { $0.submenu?.identifier?.rawValue == "Window" })?.submenu
    NSApp.helpMenu =
      main.items.first(where: { $0.submenu?.identifier?.rawValue == "Help" })?.submenu
    NSApp.mainMenu = main
    shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let menu = self.menu, NSApp.mainMenu === menu else { return event }
      if let store = self.privateHost?.activeOwner?.store ?? self.activeContext?.store,
        NextTabShortcutRouting.route(event, store: store)
          || PreviousTabShortcutRouting.route(event, store: store)
      {
        return nil
      }
      if let store = self.privateHost?.activeOwner?.store ?? self.activeContext?.store,
        TabNumberShortcutRouting.route(event, store: store)
      {
        return nil
      }
      if self.performDeveloperToolsKey(event) {
        return nil
      }
      guard
        ShortcutPageRouting.route(event, menu: menu, responder: event.window?.firstResponder)
      else { return event }
      return nil
    }
  }

  enum LaunchResult {
    case exited(Int32)
    case restart
  }

  static func makeRuntime(frameworkURL: URL) throws -> ARCChromiumRuntime {
    try ARCShaarRuntime(frameworkURL: frameworkURL)
  }

  static func run(frameworkURL: URL) -> LaunchResult {
    BrowserLanguage.applyToCurrentProcess()
    let launchLanguage = BrowserLanguage.currentLaunchLanguage
    ARCConfigureLocalization(BrowserLocalization.resourceBundleURL, launchLanguage.localeIdentifier)
    do {
      let directory = URL.applicationSupportDirectory.appending(
        path: ProductIdentity.dataFolderName, directoryHint: .isDirectory)
      let firstRunMarker = try FirstRunState.pendingMarker(in: directory)
      let lock = try WorkspaceProcessLock(directory: directory)
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: directory.appending(path: "workspace.json"),
          legacySessionURL: directory.appending(path: "session.json")),
        faviconCache: FaviconCache(
          directory: directory.appending(path: "favicons", directoryHint: .isDirectory)))
      let preferences = BrowserPreferencesStore(
        fileURL: directory.appending(path: "preferences.json"))
      let runtime = try makeRuntime(frameworkURL: frameworkURL)
      runtime.languageIdentifier = launchLanguage.localeIdentifier
      BrowserSettingsAppearance.apply(
        UserDefaults.standard.string(forKey: "settingsAppearance") ?? "system")
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        preferences: preferences, firstRunMarker: firstRunMarker)
      NSAppleEventManager.shared().setEventHandler(
        host, andSelector: #selector(handleURL(_:reply:)),
        forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
      NSAppleEventManager.shared().setEventHandler(
        host, andSelector: #selector(handleOpenDocuments(_:reply:)),
        forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
      host.fileOpenHandlerInstalled = true
      runtime.onReady = { [weak host] in
        host?.updater = AppUpdater.forMainBundle()
        do {
          try host?.restore()
          host?.installReopenHandler()
        } catch {
          host?.startupFailed = true
          host?.report(error)
          host?.events.quit()
        }
      }
      return withExtendedLifetime((host, lock)) {
        let code = runtime.run(
          withDataDirectory: directory.appending(path: "Chromium"), testing: false)
        host.detach()
        // Saves run on a background queue; the process must not exit before the last one lands.
        try? workspace.flushSaves()
        return host.restartRequested ? .restart : .exited(host.startupFailed ? 1 : code)
      }
    } catch {
      FileHandle.standardError.write(Data("\(StartupFailureMessage.text(for: error))\n".utf8))
      return .exited(1)
    }
  }
}
