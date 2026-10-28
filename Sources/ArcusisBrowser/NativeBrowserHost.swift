import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

enum BrowserMenuCommand: String, CaseIterable {
  case newWindow, newPrivateWindow, newMiniWindow, newTab, search, newSpace, editSpace, closeTab, closeWindow,
    addFavorite
  case reopenClosed, recentlyClosed, bookmarkPage, bookmarks, history, downloads
  case find, findNext, findPrevious, sidebar, nextSpace, previousSpace, reload, splitView
  case extensions, help, minimizeWindow, zoomWindow, bringAllToFront, settings, quit
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
  private(set) var menu: NSMenu?
  private(set) var lastError: String?
  private let presentation: Presentation
  private let usesPrimaryWindow: Bool
  private let keyWindow: () -> NSWindow?
  private let screens: () -> [NSRect]
  let preferences: BrowserPreferencesStore
  private(set) var settingsController: BrowserSettingsController?
  private var privateHost: PrivateBrowserHost?
  private var miniWindows: [String: MiniBrowserController] = [:]
  private var pendingURLs: [URL] = []
  private var claimedPrimary = false
  private var started = false
  private var startupFailed = false
  private var previousMenu: NSMenu?
  private var previousServicesMenu: NSMenu?
  private var previousWindowsMenu: NSMenu?
  private var previousHelpMenu: NSMenu?
  private var engineRequestedWindows: Set<String> = []
  var onClosed: ((UUID, Bool) -> Void)?

  init(
    events: BrowserRuntimeEvents, workspace: BrowserWorkspaceStore,
    preferences: BrowserPreferencesStore = BrowserPreferencesStore(),
    presentation: Presentation = .visible, usesPrimaryWindow: Bool = true,
    keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
    screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
  ) {
    self.events = events
    self.workspace = workspace
    self.preferences = preferences
    self.presentation = presentation
    self.usesPrimaryWindow = usesPrimaryWindow
    self.keyWindow = keyWindow
    self.screens = screens
    super.init()
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

  func restore() throws {
    guard !started else { throw WorkspaceError.invalidState }
    started = true
    if presentation == .visible && UserDefaults.standard.bool(forKey: "settingsStartFresh") {
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
      sourceProfileID: { [weak self] in
        if let privateSource = self?.privateHost?.activeOwner?.sourceProfileID {
          return privateSource
        }
        return self?.activeContext?.store.session.selectedSpace.profileID.uuidString
      })
    self.privateHost = privateHost
    privateHost.installCallbacks()
    events.onWindowRequest = { [weak self] profile, type in
      self?.requestedWindow(profile: profile, type: type)
    }
    events.onWindowShowRequest = { [weak self] window, active in
      self?.showRequestedWindow(window, active: active)
    }
    events.onNewTabWillAdopt = { [weak self] tab, profile, opener in
      self?.prepareNewTab(tab, profile: profile, opener: opener)
    }
    settingsController = BrowserSettingsController(
      workspace: workspace, preferences: preferences, runtime: events.runtime,
      presentation: presentation == .visible ? .visible : .hiddenProbe)
    if presentation == .visible, let controller = settingsController?.nativeBitwardenController {
      for context in contexts.values { context.engine.attachPasswordFill(controller) }
    }
    installMenus()
    if presentation == .visible {
      for context in contexts.values where context.id != focused { context.window.orderFront(nil) }
      (focused.flatMap { contexts[$0] } ?? contexts.values.first)?.window.makeKeyAndOrderFront(nil)
    }
    for url in pendingURLs { openExternalURL(url) }
    pendingURLs.removeAll()
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

  func canPerform(_ command: BrowserMenuCommand) -> Bool {
    guard !events.runtime.isQuitting else { return false }
    if command == .newWindow || command == .newMiniWindow || command == .quit { return true }
    if command == .newPrivateWindow {
      return activeContext != nil || privateHost?.hasActiveWindow == true
    }
    if privateHost?.hasActiveWindow == true {
      return privateHost?.canPerform(command) == true
    }
    if command == .settings {
      guard let context = activeContext else { return true }
      return context.store.sheet == nil && context.window.attachedSheet == nil
    }
    if let settingsWindow = settingsController?.window, keyWindow() === settingsWindow {
      return command == .closeTab || command == .closeWindow
    }
    guard let context = activeContext, context.store.sheet == nil,
      context.window.attachedSheet == nil
    else { return false }
    switch command {
    case .find: return context.store.canFindCurrentPage
    case .findNext, .findPrevious: return context.store.pageFind?.canMove == true
    case .reload: return context.store.canReloadCurrentPage
    case .splitView: return context.store.session.selectedSpace.tabs.count >= 2
    case .reopenClosed: return context.store.canReopenClosedTab
    case .bookmarkPage: return context.store.canBookmarkCurrentPage
    case .addFavorite: return context.store.canFavoriteCurrentPage
    default: return true
    }
  }

  func perform(_ command: BrowserMenuCommand) {
    guard canPerform(command) else { return }
    if command == .quit {
      if UserDefaults.standard.bool(forKey: "settingsWarnBeforeQuit") && presentation == .visible {
        let alert = NSAlert()
        alert.messageText = "Quit Arcusis Browser?"
        alert.informativeText = "Your windows and tabs will be saved."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
      }
      flushGeometry()
      workspace.persistSnapshot()
      events.runtime.quit()
      return
    }
    if command == .newMiniWindow {
      openMiniWindow(url: nil)
      return
    }
    if command == .newWindow {
      do { try newWindow(from: activeContext?.id) } catch { report(error) }
      return
    }
    if command == .newPrivateWindow {
      do { try privateHost?.openWindow() } catch { report(error) }
      return
    }
    if privateHost?.hasActiveWindow == true {
      privateHost?.perform(command)
      return
    }
    if command == .settings {
      settingsController?.show(for: activeContext?.store.session.selectedSpace.profileID)
      return
    }
    if let settingsWindow = settingsController?.window, keyWindow() === settingsWindow {
      settingsController?.close()
      return
    }
    guard let context = activeContext else { return }
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
    case .closeTab:
      if store.session.selectedPage != nil {
        store.closeCurrentPage()
      } else {
        events.runtime.closeWindowID(context.nativeID)
      }
    case .addFavorite: _ = store.addCurrentPageAsFavorite()
    case .closeWindow: events.runtime.closeWindowID(context.nativeID)
    case .reopenClosed: store.reopenLastClosedTab()
    case .recentlyClosed: store.showRecentlyClosed()
    case .bookmarkPage: store.bookmarkCurrentPage()
    case .bookmarks: store.showLibrary(.bookmarks)
    case .history: store.showLibrary(.history)
    case .downloads: store.showDownloads()
    case .find: store.showPageFind()
    case .findNext: store.movePageFind(forward: true)
    case .findPrevious: store.movePageFind(forward: false)
    case .sidebar: store.sidebarIsVisible.toggle()
    case .nextSpace: store.cycleSpace(by: 1)
    case .previousSpace: store.cycleSpace(by: -1)
    case .reload: store.reloadCurrentPage()
    case .splitView: store.splitSelectedTab()
    case .extensions: context.engine.showExtensionList()
    case .help:
      if let url = URL(string: "https://github.com/arcusis/browser") { store.perform(.open(url)) }
    case .minimizeWindow: context.window.performMiniaturize(nil)
    case .zoomWindow: context.window.zoom(nil)
    case .bringAllToFront:
      for browser in contexts.values { browser.window.orderFront(nil) }
      context.window.makeKeyAndOrderFront(nil)
    case .newWindow, .newPrivateWindow, .newMiniWindow, .settings, .quit: break
    }
  }

  func flushGeometry() {
    for context in contexts.values { saveGeometry(context) }
  }

  func detach() {
    privateHost?.detach()
    privateHost = nil
    events.onWindowRequest = nil
    events.onWindowShowRequest = nil
    events.onNewTabWillAdopt = nil
    for context in contexts.values {
      stopObserving(context)
      context.engine.detachPasswordFill()
      context.engine.onClosed = nil
    }
    if NSApp.mainMenu === menu { NSApp.mainMenu = previousMenu }
    if NSApp.servicesMenu
      === menu?.items.first?.submenu?.items.first(where: {
        $0.submenu?.title == "Services"
      })?.submenu
    {
      NSApp.servicesMenu = previousServicesMenu
    }
    if NSApp.windowsMenu === menu?.items.first(where: { $0.submenu?.title == "Window" })?.submenu {
      NSApp.windowsMenu = previousWindowsMenu
    }
    if NSApp.helpMenu === menu?.items.first(where: { $0.submenu?.title == "Help" })?.submenu {
      NSApp.helpMenu = previousHelpMenu
    }
  }

  @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: text), NavigationInput.isWebURL(url) else { return }
    if !started { pendingURLs.append(url); return }
    openExternalURL(url)
  }

  private func openExternalURL(_ url: URL) {
    guard let context = activeContext ?? workspace.workspace.focusedWindowID.flatMap({ contexts[$0] })
      ?? contexts.values.first else { return }
    switch MiniLinkRoute.route(url, inMainWindow: UserDefaults.standard.bool(forKey: "externalLinksInMainWindow")) {
    case .main(let url):
      context.store.perform(.open(url))
      context.window.makeKeyAndOrderFront(nil)
    case .mini(let url):
      openMiniWindow(url: url, context: context)
    case nil: break
    }
  }

  @discardableResult
  private func openMiniWindow(url: URL?, context: NativeBrowserContext? = nil, destination: UUID? = nil) -> Bool {
    guard let target = context ?? activeContext ?? workspace.workspace.focusedWindowID.flatMap({ contexts[$0] })
      ?? contexts.values.first else { return false }
    do {
      let mini = try MiniBrowserController(events: events, target: target.store, targetWindow: target.window, url: url, destination: destination)
      let id = mini.engine.windowID
      miniWindows[id] = mini
      mini.onClosed = { [weak self] in self?.miniWindows[id] = nil }
      mini.onProfileChange = { [weak self, weak target] destination, url in
        guard let self, let target else { return false }
        return self.openMiniWindow(url: url, context: target, destination: destination)
      }
      return true
    } catch { report(error); return false }
  }

  private func attach(_ id: UUID, source: NSRect?, reconcile: Bool = true) throws {
    guard let store = workspace.stores[id], let record = workspace.workspace.window(id) else {
      throw WorkspaceError.unknownWindow
    }
    store.usePreferences(preferences)
    let runtime = events.runtime
    let nativeID: String
    if usesPrimaryWindow && !claimedPrimary && runtime.window != nil {
      claimedPrimary = true
      nativeID = runtime.primaryWindowID
    } else {
      nativeID = id.uuidString
      try runtime.createWindowID(nativeID)
    }
    guard let window = runtime.window(forID: nativeID),
      let content = runtime.hostView(forWindowID: nativeID)
    else {
      throw WorkspaceError.invalidState
    }
    let engine = try BrowserEngine(
      events: events, windowID: nativeID, store: store,
      presentsNativePanels: presentation == .visible,
      lazyPinnedTabs: true)
    if presentation == .visible, let controller = settingsController?.nativeBitwardenController {
      engine.attachPasswordFill(controller)
    }
    let hosting = NSHostingView(rootView: BrowserWindow(store: store))
    window.title = "Arcusis Browser"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.isMovable = true
    window.minSize = NSSize(width: 760, height: 520)
    window.setFrame(
      NativeWindowPlacement.frame(saved: record.geometry, source: source, screens: screens()),
      display: false)
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    // Chromium's embed container can exclude the native titlebar. Install the
    // safe strip in the window frame so its geometry includes that top edge.
    let titlebarHost = window.contentView?.superview ?? content
    let titlebarDragView = WindowDragRegion.makeTitlebarDragView(
      window: window, contentView: titlebarHost)
    titlebarHost.addSubview(titlebarDragView, positioned: .above, relativeTo: nil)
    let context = NativeBrowserContext(
      id: id, nativeID: nativeID, window: window, store: store, engine: engine, hosting: hosting,
      contentView: content, titlebarDragView: titlebarDragView)
    contexts[id] = context
    engine.onClosed = { [weak self] quitting in self?.closed(id, quitting: quitting) }
    observe(context)
    if reconcile { engine.reconcile() }
  }

  private func requestedWindow(profile: String, type: String) -> String? {
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

  private func showRequestedWindow(_ nativeID: String, active: Bool) {
    // The engine can request visibility during insertion. Present only once its
    // notification has unwound and the application has adopted the page.
    DispatchQueue.main.async { [weak self] in
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
        forName: NSWindow.didBecomeKeyNotification, object: context.window, queue: .main
      ) {
        [weak self, weak context] _ in
        MainActor.assumeIsolated {
          guard let self, let context else { return }
          context.engine.passwordWindowKeyChanged(true)
          do { try self.workspace.focusWindow(context.id) } catch { self.report(error) }
        }
      })
    context.observers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification, object: context.window, queue: .main
      ) {
        [weak context] _ in
        MainActor.assumeIsolated { context?.engine.passwordWindowKeyChanged(false) }
      })
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      context.observers.append(
        center.addObserver(forName: name, object: context.window, queue: .main) {
          [weak self, weak context] _ in
          MainActor.assumeIsolated {
            guard let self, let context else { return }
            WindowDragRegion.updateTitlebarDragView(
              context.titlebarDragView, window: context.window,
              contentView: context.titlebarDragView.superview ?? context.contentView)
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
    guard let context = contexts.removeValue(forKey: id) else { return }
    engineRequestedWindows.remove(context.nativeID)
    stopObserving(context)
    saveGeometry(context)
    if !quitting {
      do { try workspace.removeWindow(id) } catch { report(error) }
    } else {
      workspace.persistSnapshot()
    }
    onClosed?(id, quitting)
  }

  private func stopObserving(_ context: NativeBrowserContext) {
    context.titlebarDragView.removeFromSuperview()
    context.geometryTask?.cancel()
    context.geometryTask = nil
    for observer in context.observers { NotificationCenter.default.removeObserver(observer) }
    context.observers.removeAll()
  }

  private func report(_ error: Error) {
    lastError = error.localizedDescription
    activeContext?.engine.reportNotice(error.localizedDescription)
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if let id = item.representedObject as? UUID {
      guard canPerform(.nextSpace), let store = activeContext?.store else { return false }
      item.state = store.session.selectedSpaceID == id ? .on : .off
      return store.session.spaces.contains { $0.id == id }
    }
    if item.action == #selector(copyCurrentURL(_:)) {
      return canPerform(.nextSpace) && activeContext?.store.session.selectedPage != nil
    }
    guard let raw = item.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return false }
    if command == .closeTab {
      item.title =
        activeContext?.store.session.selectedPage == nil
        ? "Close window" : "Close tab"
    }
    return canPerform(command)
  }

  static func makeMenu(target: AnyObject) -> NSMenu {
    let main = NSMenu()
    func section(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let result = NSMenu(title: title)
      item.submenu = result
      main.addItem(item)
      return result
    }
    func add(
      _ command: BrowserMenuCommand, _ title: String, _ key: String, to menu: NSMenu,
      modifiers: NSEvent.ModifierFlags = .command
    ) {
      let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
      item.target = target
      item.representedObject = command.rawValue
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    let app = section("Arcusis Browser")
    app.addItem(
      withTitle: "About Arcusis Browser",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let services = NSMenu(title: "Services")
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    app.addItem(servicesItem)
    app.addItem(.separator())
    add(.settings, "Settings…", ",", to: app)
    app.addItem(
      NSMenuItem(
        title: "Hide Arcusis Browser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
      ))
    app.addItem(
      NSMenuItem(
        title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h"))
    app.items.last?.keyEquivalentModifierMask = [.command, .option]
    app.addItem(
      NSMenuItem(
        title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""))
    app.addItem(.separator())
    add(.quit, "Quit Arcusis Browser", "q", to: app)
    let file = section("File")
    add(.newWindow, "New window", "n", to: file)
    add(.newPrivateWindow, "New Private Window", "n", to: file, modifiers: [.command, .shift])
    add(.newMiniWindow, "New Mini Window", "n", to: file, modifiers: [.command, .option])
    add(.newTab, "New tab", "t", to: file)
    add(.search, "Search or enter address", "l", to: file)
    add(.closeWindow, "Close window", "w", to: file, modifiers: [.command, .shift])
    let edit = section("Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
      ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
    }
    edit.addItem(.separator())
    add(.find, "Find in Page…", "f", to: edit)
    add(.findNext, "Find Next", "g", to: edit)
    add(.findPrevious, "Find Previous", "g", to: edit, modifiers: [.command, .shift])
    let view = section("View")
    add(.sidebar, "Toggle sidebar", "s", to: view)
    add(.reload, "Reload", "r", to: view)
    let spaces = section("Spaces")
    add(.newSpace, "New space…", "", to: spaces)
    add(.editSpace, "Edit current space…", "", to: spaces)
    add(
      .nextSpace, "Next space", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
      to: spaces, modifiers: [.command, .option])
    add(
      .previousSpace, "Previous space", String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
      to: spaces, modifiers: [.command, .option])
    let copyURL = NSMenuItem(
      title: "Copy URL", action: #selector(copyCurrentURL(_:)), keyEquivalent: "c")
    copyURL.target = target
    copyURL.keyEquivalentModifierMask = [.command, .shift]
    spaces.addItem(copyURL)
    let tabs = section("Tabs")
    add(.splitView, "Split View", "=", to: tabs, modifiers: [.control, .shift])
    add(.closeTab, "Close tab", "w", to: tabs)
    add(.addFavorite, "Add to Favorites", "", to: tabs, modifiers: [])
    add(.reopenClosed, "Reopen last closed tab", "t", to: tabs, modifiers: [.command, .shift])
    let archive = section("Archive")
    add(.recentlyClosed, "Recently closed…", "", to: archive)
    add(.bookmarkPage, "Bookmark this page", "d", to: archive)
    add(.bookmarks, "Bookmarks…", "", to: archive)
    add(.history, "History…", "y", to: archive)
    add(.downloads, "Downloads", "j", to: archive, modifiers: [.command, .shift])
    let extensions = section("Extensions")
    add(.extensions, "Manage Extensions…", "", to: extensions)
    let window = section("Window")
    add(.minimizeWindow, "Minimize", "m", to: window)
    add(.zoomWindow, "Zoom", "", to: window)
    add(.bringAllToFront, "Bring All to Front", "", to: window)
    let help = section("Help")
    add(.help, "Arcusis Browser Support", "", to: help)
    return main
  }

  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return }
    (sender.target as? NativeBrowserHost)?.perform(command)
  }

  @objc private func copyCurrentURL(_ sender: NSMenuItem) {
    guard canPerform(.nextSpace), let url = activeContext?.store.session.selectedPage?.tab.url
    else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  @objc private func selectMenuSpace(_ sender: NSMenuItem) {
    guard canPerform(.nextSpace), let id = sender.representedObject as? UUID,
      let store = activeContext?.store,
      store.session.spaces.contains(where: { $0.id == id })
    else { return }
    store.perform(.space(id))
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu.title == "Spaces" else { return }
    while let item = menu.items.first(where: { $0.representedObject is UUID || $0.tag == 91827 }) {
      menu.removeItem(item)
    }
    guard canPerform(.nextSpace), let store = activeContext?.store else { return }
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
    if let spaces = main.items.first(where: { $0.submenu?.title == "Spaces" })?.submenu {
      spaces.delegate = self
      menuNeedsUpdate(spaces)
    }
    NSApp.servicesMenu =
      main.items.first?.submenu?.items.first(where: {
        $0.submenu?.title == "Services"
      })?.submenu
    NSApp.windowsMenu = main.items.first(where: { $0.submenu?.title == "Window" })?.submenu
    NSApp.helpMenu = main.items.first(where: { $0.submenu?.title == "Help" })?.submenu
    NSApp.mainMenu = main
  }

  static func run(frameworkURL: URL) -> Int32 {
    do {
      let directory = URL.applicationSupportDirectory.appending(
        path: "Arcusis Browser", directoryHint: .isDirectory)
      let lock = try WorkspaceProcessLock(directory: directory)
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: directory.appending(path: "workspace.json"),
          legacySessionURL: directory.appending(path: "session.json")))
      let preferences = BrowserPreferencesStore(
        fileURL: directory.appending(path: "preferences.json"))
      BrowserSettingsAppearance.apply(UserDefaults.standard.string(forKey: "settingsAppearance") ?? "system")
      let runtime = try ARCChromiumRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        preferences: preferences)
      NSAppleEventManager.shared().setEventHandler(host, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
      runtime.onReady = { [weak host] in
        do { try host?.restore() } catch {
          host?.startupFailed = true
          host?.report(error)
          host?.events.runtime.quit()
        }
      }
      return withExtendedLifetime((host, lock)) {
        let code = runtime.run(
          withDataDirectory: directory.appending(path: "Chromium"), testing: false)
        host.detach()
        return host.startupFailed ? 1 : code
      }
    } catch {
      FileHandle.standardError.write(
        Data("Browser startup failed: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}
