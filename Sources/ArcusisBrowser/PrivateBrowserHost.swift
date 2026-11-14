// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@MainActor
final class PrivateBrowserHost {
  struct Owner {
    let contextID: String
    let sourceProfileID: String
    let windowID: String
    let store: BrowserStore
    let page: PrivatePageSession
    let window: NSWindow
    let hosting: NSHostingView<BrowserWindow?>
    let titlebarDragView: NSView
  }

  private let runtime: ARCChromiumRuntime
  private let keyWindow: () -> NSWindow?
  private let toggleFullScreen: (NSWindow) -> Void
  private let sourceProfileID: () -> String?
  private let presentsWindows: Bool
  private let preferences: BrowserPreferencesStore
  private let profileIsDownloading: (UUID) -> Bool
  private let reportError: (Error) -> Void
  private var owners: [String: Owner] = [:]
  private var contextsBySource: [String: String] = [:]
  private var windowsByContext: [String: Set<String>] = [:]
  private var pendingWindowRequests: [String: [(String, String)]] = [:]
  private var contextsAwaitingRelease: Set<String> = []
  private var contextReleaseRetryTask: Task<Void, Never>?
  private var isDetached = false

  init(
    runtime: ARCChromiumRuntime, presentsWindows: Bool = true,
    keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
    toggleFullScreen: @escaping (NSWindow) -> Void = { $0.toggleFullScreen(nil) },
    preferences: BrowserPreferencesStore = BrowserPreferencesStore(),
    profileIsDownloading: @escaping (UUID) -> Bool = { _ in false },
    reportError: @escaping (Error) -> Void = { NSApp.presentError($0) },
    sourceProfileID: @escaping () -> String?
  ) {
    self.runtime = runtime
    self.presentsWindows = presentsWindows
    self.keyWindow = keyWindow
    self.toggleFullScreen = toggleFullScreen
    self.preferences = preferences
    self.profileIsDownloading = profileIsDownloading
    self.reportError = reportError
    self.sourceProfileID = sourceProfileID
  }

  var activeOwner: Owner? {
    var window = keyWindow()
    while let parent = window?.sheetParent { window = parent }
    return owners.values.first { $0.window === window }
  }
  var hasActiveWindow: Bool { activeOwner != nil }
  var ownedWindows: [Owner] { Array(owners.values) }
  var windowCount: Int { owners.count }

  func installCallbacks() {
    runtime.onPrivateNavigationFailed = { [weak self] context, window, tab, message in
      guard let owner = self?.owner(context: context, window: window),
        owner.store.session.selectedPage?.tab.id.uuidString == tab
      else { return }
      owner.page.navigationFailed(message)
    }
    runtime.onPrivateTabChanged = {
      [weak self] context, window, tab, url, title, loading, back, forward in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab)
      else { return }
      owner.page.tabChanged(
        id, url: url, title: title, loading: loading,
        back: back, forward: forward)
    }
    runtime.onPrivateTabSelected = { [weak self] context, window, tab in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab)
      else { return }
      owner.page.tabSelected(id)
    }
    runtime.onPrivateFindResult = {
      [weak self] context, window, tab, request, count, active, final in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab), let token = UUID(uuidString: request)
      else { return }
      owner.store.receiveFindResult(
        tabID: id, requestID: token, count: Int(count), active: Int(active), final: final)
    }
    runtime.onPrivateTabClosed = { [weak self] context, window, tab in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab)
      else { return }
      owner.page.tabClosed(id)
    }
    runtime.onPrivateTabLifecycle = {
      [weak self] context, window, tab, state, audible, capturing in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab)
      else { return }
      owner.page.applyLifecycle(id, state: state, audible: audible, capturing: capturing)
    }
    runtime.onPrivateMediaAccess = { [weak self] context, window, tab, access in
      guard let owner = self?.owner(context: context, window: window),
        let id = UUID(uuidString: tab)
      else { return }
      owner.page.noteMediaAccess(
        id, camera: access["camera"]?.boolValue ?? false,
        microphone: access["microphone"]?.boolValue ?? false,
        screen: access["screen"]?.boolValue ?? false)
    }
    runtime.onPrivatePrintRequest = { [weak self] context, window, tab, request in
      guard let owner = self?.owner(context: context, window: window),
        let tabID = UUID(uuidString: tab),
        let profileID = UUID(uuidString: request["profileID"] as? String ?? ""),
        owner.page.ownsLiveTab(tabID, profileID: profileID)
      else {
        if let id = request["id"] as? String {
          self?.runtime.resolvePrintRequestID(id, accepted: false)
        }
        return
      }
      owner.page.receivePrintRequest(request, tabID: tab)
    }
    runtime.onPrivateWindowClosed = { [weak self] context, window in
      self?.windowClosed(context: context, window: window)
    }
  }

  private func owner(context: String, window: String) -> Owner? {
    guard let owner = owners[window], owner.contextID == context else { return nil }
    return owner
  }

  func openDevToolsRequestedURL(_ request: DevToolsOpenURLRequest) {
    guard let contextID = request.contextID,
      let owner = owner(context: contextID, window: request.windowID),
      owner.page.ownsLiveTab(request.tabID, profileID: request.profileID)
    else { return }
    _ = owner.store.openDevToolsRequestedTab(
      request.url, sourceTabID: request.tabID, profileID: request.profileID)
  }

  func detach() {
    guard !isDetached else {
      retryPendingContextReleases()
      return
    }
    isDetached = true
    contextReleaseRetryTask?.cancel()
    contextReleaseRetryTask = nil
    runtime.onPrivateNavigationFailed = nil
    runtime.onPrivateTabChanged = nil
    runtime.onPrivateTabSelected = nil
    runtime.onPrivateFindResult = nil
    runtime.onPrivateTabClosed = nil
    runtime.onPrivateTabLifecycle = nil
    runtime.onPrivateMediaAccess = nil
    runtime.onPrivatePrintRequest = nil
    runtime.onPrivateWindowClosed = nil
    for owner in owners.values { retire(owner) }
    owners.removeAll()
    retryPendingContextReleases()
  }

  static func retireHostingContent<Content: View>(_ hosting: NSHostingView<Content?>) {
    hosting.rootView = nil
    hosting.layoutSubtreeIfNeeded()
    hosting.removeFromSuperview()
  }

  private func retire(_ owner: Owner) {
    owner.page.retireInspectors()
    owner.window.endEditing(for: nil)
    _ = owner.window.makeFirstResponder(nil)
    Self.retireHostingContent(owner.hosting)
    owner.titlebarDragView.removeFromSuperview()
    owner.store.onSessionChanged = nil
    owner.store.onCloseTab = nil
    owner.store.onReloadPage = nil
    owner.store.onNavigatePage = nil
    owner.store.onFindRequest = nil
    owner.store.onStopFinding = nil
    owner.store.privatePage = nil
  }

  func openWindow() throws {
    guard !isDetached, !runtime.isQuitting, let source = sourceProfileID() else {
      throw WorkspaceError.invalidState
    }
    retryPendingContextReleases()
    let contextID = contextsBySource[source] ?? UUID().uuidString.uppercased()
    let windowID = UUID().uuidString.uppercased()
    let tabID = UUID().uuidString.uppercased()
    if let context = contextsBySource[source] {
      if pendingWindowRequests[context] != nil {
        pendingWindowRequests[context, default: []].append((windowID, tabID))
      } else {
        createWindow(context: context, source: source, window: windowID, tab: tabID)
      }
      return
    }
    contextsBySource[source] = contextID
    windowsByContext[contextID] = []
    pendingWindowRequests[contextID] = [(windowID, tabID)]
    let runtime = self.runtime
    runtime.createPrivateContextID(contextID, sourceProfileID: source) {
      [weak self, runtime] success, error in
      guard let self else {
        if success, !runtime.releasePrivateContextID(contextID) {
          _ = runtime.releasePrivateContextID(contextID)
        }
        return
      }
      if self.isDetached {
        self.pendingWindowRequests.removeValue(forKey: contextID)
        if self.contextsBySource[source] == contextID {
          self.contextsBySource.removeValue(forKey: source)
        }
        self.windowsByContext.removeValue(forKey: contextID)
        if success {
          self.releaseContext(contextID)
          self.retryPendingContextReleases()
        }
        return
      }
      guard success else {
        self.pendingWindowRequests.removeValue(forKey: contextID)
        if self.contextsBySource[source] == contextID {
          self.contextsBySource.removeValue(forKey: source)
        }
        self.windowsByContext.removeValue(forKey: contextID)
        if !self.runtime.isQuitting {
          self.reportError(
            error ?? NSError(
              domain: "org.arcusis.shaar.private-window", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "The private window context could not be created."]
            ))
        }
        return
      }
      guard !self.runtime.isQuitting, self.contextsBySource[source] == contextID,
        self.windowsByContext[contextID] != nil
      else {
        self.pendingWindowRequests.removeValue(forKey: contextID)
        if self.contextsBySource[source] == contextID {
          self.contextsBySource.removeValue(forKey: source)
        }
        if self.windowsByContext[contextID]?.isEmpty == true {
          self.windowsByContext.removeValue(forKey: contextID)
        }
        if self.windowsByContext[contextID] == nil {
          self.releaseContext(contextID)
        }
        return
      }
      let requests = self.pendingWindowRequests[contextID] ?? []
      for (index, (window, tab)) in requests.enumerated() {
        self.pendingWindowRequests[contextID] = Array(requests.dropFirst(index + 1))
        self.createWindow(context: contextID, source: source, window: window, tab: tab)
      }
      self.pendingWindowRequests.removeValue(forKey: contextID)
    }
  }

  static func supportsPrivateCommand(_ command: BrowserMenuCommand) -> Bool {
    switch command {
    case .bookmarkPage, .bookmarks, .history, .downloads, .extensions, .settings,
      .newMiniWindow, .checkForUpdates:
      false
    default: true
    }
  }

  func canPerform(_ command: BrowserMenuCommand) -> Bool {
    guard let owner = activeOwner, !runtime.isQuitting,
      Self.supportsPrivateCommand(command), owner.store.sheet == nil
    else { return false }
    return Self.windowCanPerform(command, store: owner.store)
  }

  static func windowCanPerform(_ command: BrowserMenuCommand, store: BrowserStore) -> Bool {
    return switch command {
    case .back:
      store.session.selectedPage.flatMap { store.privatePage?.pages[$0.tab.id] }?.canGoBack == true
    case .forward:
      store.session.selectedPage.flatMap { store.privatePage?.pages[$0.tab.id] }?.canGoForward == true
    case .closeTab: !store.commandIsOpen || store.session.selectedPage == nil
    case .developerTools, .chromiumDeveloperTools, .inspector:
      !store.commandIsOpen && store.privatePage?.inspectorTarget != nil
    case .inspectorCopy, .inspectorSource, .inspectorAgentCopy:
      store.session.selectedPage.flatMap { store.privatePage?.inspectors[$0.tab.id] }?
        .aiCopy.canCopy == true
    case .reopenClosed: store.canReopenClosedTab
    case .splitView: store.canSplitSelectedTab
    case .addFavorite: store.canFavoriteCurrentPage
    case .nextSpace, .previousSpace: store.canCycleSpace
    case .reload, .hardReload: store.canReloadCurrentPage
    case .find: store.canFindCurrentPage
    case .findNext, .findPrevious: store.pageFind?.canMove == true
    case .sharePage:
      !store.commandIsOpen && NativeBrowserHost.shareURL(for: store) != nil
    default: true
    }
  }

  func perform(_ command: BrowserMenuCommand) {
    guard let owner = activeOwner, canPerform(command) else { return }
    let store = owner.store
    switch command {
    case .back:
      if let id = store.session.selectedPage?.tab.id { owner.page.goBack(id) }
    case .forward:
      if let id = store.session.selectedPage?.tab.id { owner.page.goForward(id) }
    case .developerTools: owner.page.toggleChromiumDeveloperTools()
    case .chromiumDeveloperTools: owner.page.toggleChromiumDeveloperTools()
    case .inspector: owner.page.toggleInspector()
    case .inspectorCopy:
      if let target = owner.page.inspectorTarget,
        let inspector = owner.page.inspectors[target.tabID]
      {
        Task { await inspector.aiCopy.copyElement() }
      }
    case .inspectorSource:
      if let target = owner.page.inspectorTarget,
        let inspector = owner.page.inspectors[target.tabID]
      {
        Task { await inspector.sourceActions.open() }
      }
    case .inspectorAgentCopy:
      if let target = owner.page.inspectorTarget,
        let inspector = owner.page.inspectors[target.tabID]
      {
        Task { await inspector.sourceActions.copyForAgent() }
      }
    case .newTab: store.showCommand()
    case .search: store.showAddressEditor()
    case .newSpace: store.spaceEditor = .create
    case .editSpace: store.spaceEditor = .edit(store.session.selectedSpaceID)
    case .createFolder:
      store.showFolderEditor(.create(spaceID: store.session.selectedSpaceID, parentID: nil))
    case .closeTab:
      if store.session.selectedPage != nil { store.closeCurrentPage() } else { closeWindow(owner) }
    case .closeWindow: closeWindow(owner)
    case .reopenClosed: store.reopenLastClosedTab()
    case .recentlyClosed: store.showRecentlyClosed()
    case .addFavorite: _ = store.addCurrentPageAsFavorite()
    case .sidebar: store.sidebarIsVisible.toggle()
    case .nextSpace: store.cycleSpace(by: 1)
    case .previousSpace: store.cycleSpace(by: -1)
    case .reload: _ = store.reloadCurrentPage()
    case .hardReload: _ = store.reloadCurrentPage(.bypassingCache)
    case .sharePage:
      if let url = NativeBrowserHost.shareURL(for: store) {
        NativeBrowserHost.presentSharePicker(for: url, in: owner.window)
      }
    case .find: store.showPageFind()
    case .findNext: store.movePageFind(forward: true)
    case .findPrevious: store.movePageFind(forward: false)
    case .splitView: store.splitSelectedTab()
    case .help:
      if let url = URL(string: "https://github.com/arcusis/shaar") { store.perform(.open(url)) }
    case .minimizeWindow: owner.window.performMiniaturize(nil)
    case .zoomWindow: owner.window.zoom(nil)
    case .fullScreen: toggleFullScreen(owner.window)
    case .bringAllToFront:
      for item in owners.values { item.window.orderFront(nil) }
      owner.window.makeKeyAndOrderFront(nil)
    default: break
    }
  }

  private func createWindow(context: String, source: String, window: String, tab: String) {
    guard !runtime.isQuitting, let sourceID = UUID(uuidString: source),
      let firstTabID = UUID(uuidString: tab),
      let session = try? BrowserSession.privateWindow(
        sourceProfileID: sourceID, firstTabID: firstTabID)
    else { return }
    do {
      try runtime.createPrivateWindowID(
        window, contextID: context, tabID: tab,
        url: "about:blank")
    } catch {
      releaseEmptyContext(context, source: source)
      return
    }
    guard let nativeWindow = runtime.window(forPrivateWindowID: window, contextID: context),
      let container = runtime.hostView(forPrivateWindowID: window, contextID: context)
    else {
      runtime.closePrivateWindowID(window, contextID: context) { [weak self] closed in
        if closed { self?.releaseEmptyContext(context, source: source) }
      }
      return
    }
    nativeWindow.title = ProductIdentity.name
    nativeWindow.titleVisibility = .hidden
    nativeWindow.titlebarAppearsTransparent = true
    nativeWindow.styleMask.insert(.fullSizeContentView)
    nativeWindow.isMovable = true
    nativeWindow.minSize = NSSize(width: 760, height: 520)
    nativeWindow.setFrame(
      NativeWindowPlacement.frame(
        saved: nil, source: nil, screens: NSScreen.screens.map(\.visibleFrame)),
      display: false)
    let store = BrowserStore(privateSession: session)
    store.usePreferences(preferences)
    let page = PrivatePageSession(
      runtime: runtime, contextID: context, windowID: window,
      firstTabID: firstTabID, store: store,
      profileIsDownloading: profileIsDownloading)
    let hosting = NSHostingView<BrowserWindow?>(rootView: BrowserWindow(store: store))
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    let titlebarHost = nativeWindow.contentView?.superview ?? container
    let titlebarDragView = WindowDragRegion.makeTitlebarDragView(
      window: nativeWindow, contentView: titlebarHost,
      isRightToLeft: BrowserLanguage.currentLaunchLanguage.isRightToLeft)
    titlebarHost.addSubview(titlebarDragView, positioned: .above, relativeTo: nil)
    let owner = Owner(
      contextID: context, sourceProfileID: source, windowID: window,
      store: store, page: page, window: nativeWindow,
      hosting: hosting, titlebarDragView: titlebarDragView)
    owners[window] = owner
    windowsByContext[context, default: []].insert(window)
    page.onEmpty = { [weak self] in
      guard let self, let owner = self.owners[window] else { return }
      self.closeWindow(owner)
    }
    store.launcherActions = LauncherActions(
      available: { [weak self] in self?.launcherCommands(window: window) ?? [] },
      run: { [weak self] name in self?.performLauncherCommand(name, window: window) })
    if presentsWindows { nativeWindow.makeKeyAndOrderFront(nil) }
  }

  private func launcherCommands(window: String) -> [LauncherCommand] {
    guard owners[window] != nil else { return [] }
    return LauncherCommands.catalog.filter {
      guard let command = BrowserMenuCommand(rawValue: $0.id) else { return false }
      return Self.supportsPrivateCommand(command)
    }
  }

  private func performLauncherCommand(_ name: String, window: String) {
    guard let command = BrowserMenuCommand(rawValue: name), owners[window] != nil,
      Self.supportsPrivateCommand(command)
    else { return }
    if activeOwner?.windowID == window { perform(command) }
  }

  private func closeWindow(_ owner: Owner) {
    runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) { _ in }
  }

  private func releaseEmptyContext(_ context: String, source: String) {
    guard pendingWindowRequests[context]?.isEmpty != false,
      windowsByContext[context]?.isEmpty == true,
      contextsBySource[source] == context
    else { return }
    windowsByContext.removeValue(forKey: context)
    contextsBySource.removeValue(forKey: source)
    releaseContext(context)
  }

  private func windowClosed(context: String, window: String) {
    guard let owner = owner(context: context, window: window) else { return }
    owners.removeValue(forKey: window)
    retire(owner)
    windowsByContext[context]?.remove(window)
    if windowsByContext[context]?.isEmpty == true {
      windowsByContext.removeValue(forKey: context)
      contextsBySource.removeValue(forKey: owner.sourceProfileID)
      releaseContext(context)
    }
  }

  private func retryPendingContextReleases() {
    for context in Array(contextsAwaitingRelease) { releaseContext(context) }
  }

  private func releaseContext(_ context: String) {
    if runtime.releasePrivateContextID(context) {
      contextsAwaitingRelease.remove(context)
      if contextsAwaitingRelease.isEmpty {
        contextReleaseRetryTask?.cancel()
        contextReleaseRetryTask = nil
      }
    } else {
      contextsAwaitingRelease.insert(context)
      scheduleContextReleaseRetry()
    }
  }

  private func scheduleContextReleaseRetry() {
    guard !isDetached, !runtime.isQuitting, !contextsAwaitingRelease.isEmpty,
      contextReleaseRetryTask == nil
    else { return }
    contextReleaseRetryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard let self else { return }
      self.contextReleaseRetryTask = nil
      self.retryPendingContextReleases()
    }
  }
}
