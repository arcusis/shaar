import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

enum BrowserMenuCommand: String, CaseIterable {
  case newWindow, newTab, search, newSpace, editSpace, closeTab, closeWindow
  case reopenClosed, recentlyClosed, bookmarkPage, bookmarks, history, downloads
  case find, findNext, findPrevious, sidebar, nextSpace, previousSpace, reload, quit
}

@MainActor
final class NativeBrowserContext {
  let id: UUID
  let nativeID: String
  let window: NSWindow
  let store: BrowserStore
  let engine: BrowserEngine
  let hosting: NSHostingView<BrowserWindow>
  var observers: [NSObjectProtocol] = []
  var geometryTask: Task<Void, Never>?

  init(
    id: UUID, nativeID: String, window: NSWindow, store: BrowserStore, engine: BrowserEngine,
    hosting: NSHostingView<BrowserWindow>
  ) {
    self.id = id
    self.nativeID = nativeID
    self.window = window
    self.store = store
    self.engine = engine
    self.hosting = hosting
  }
}

/// The same host manages production windows and hidden disposable test windows.
@MainActor
final class NativeBrowserHost: NSObject, NSMenuItemValidation {
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
  private var claimedPrimary = false
  private var started = false
  private var startupFailed = false
  private var previousMenu: NSMenu?
  private var engineRequestedWindows: Set<String> = []
  var onClosed: ((UUID, Bool) -> Void)?

  init(
    events: BrowserRuntimeEvents, workspace: BrowserWorkspaceStore,
    presentation: Presentation = .visible, usesPrimaryWindow: Bool = true,
    keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
    screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
  ) {
    self.events = events
    self.workspace = workspace
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
    if workspace.workspace.windows.isEmpty { try workspace.newWindow() }
    workspace.persistSnapshot()
    let focused = workspace.workspace.focusedWindowID
    for record in workspace.workspace.windows { try attach(record.id, source: nil) }
    events.onWindowRequest = { [weak self] profile, type in
      self?.requestedWindow(profile: profile, type: type)
    }
    events.onWindowShowRequest = { [weak self] window, active in
      self?.showRequestedWindow(window, active: active)
    }
    events.onNewTabWillAdopt = { [weak self] tab, profile, opener in
      self?.prepareNewTab(tab, profile: profile, opener: opener)
    }
    installMenus()
    if presentation == .visible {
      for context in contexts.values where context.id != focused { context.window.orderFront(nil) }
      (focused.flatMap { contexts[$0] } ?? contexts.values.first)?.window.makeKeyAndOrderFront(nil)
    }
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
    if command == .newWindow || command == .quit { return true }
    guard let context = activeContext, context.store.sheet == nil,
      context.window.attachedSheet == nil
    else { return false }
    switch command {
    case .find: return context.store.canFindCurrentPage
    case .findNext, .findPrevious: return context.store.pageFind?.canMove == true
    case .reload: return context.store.canReloadCurrentPage
    case .reopenClosed: return context.store.canReopenClosedTab
    case .bookmarkPage: return context.store.canBookmarkCurrentPage
    default: return true
    }
  }

  func perform(_ command: BrowserMenuCommand) {
    guard canPerform(command) else { return }
    if command == .quit {
      flushGeometry()
      workspace.persistSnapshot()
      events.runtime.quit()
      return
    }
    if command == .newWindow {
      do { try newWindow(from: activeContext?.id) } catch { report(error) }
      return
    }
    guard let context = activeContext else { return }
    let store = context.store
    switch command {
    case .newTab, .search: store.showCommand()
    case .newSpace: store.spaceEditor = .create
    case .editSpace: store.spaceEditor = .edit(store.session.selectedSpaceID)
    case .closeTab:
      if let tab = store.session.selectedSpace.selectedTabID {
        store.closeTab(tab)
      } else {
        events.runtime.closeWindowID(context.nativeID)
      }
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
    case .newWindow, .quit: break
    }
  }

  func flushGeometry() {
    for context in contexts.values { saveGeometry(context) }
  }

  func detach() {
    events.onWindowRequest = nil
    events.onWindowShowRequest = nil
    events.onNewTabWillAdopt = nil
    for context in contexts.values {
      stopObserving(context)
      context.engine.onClosed = nil
    }
    if NSApp.mainMenu === menu { NSApp.mainMenu = previousMenu }
  }

  private func attach(_ id: UUID, source: NSRect?, reconcile: Bool = true) throws {
    guard let store = workspace.stores[id], let record = workspace.workspace.window(id) else {
      throw WorkspaceError.unknownWindow
    }
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
    let hosting = NSHostingView(rootView: BrowserWindow(store: store))
    window.title = "Arcusis Browser"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.minSize = NSSize(width: 760, height: 520)
    window.setFrame(
      NativeWindowPlacement.frame(saved: record.geometry, source: source, screens: screens()),
      display: false)
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    let context = NativeBrowserContext(
      id: id, nativeID: nativeID, window: window, store: store, engine: engine, hosting: hosting)
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
      let space = source.store.session.spaces.first(where: {
        $0.profileID == profileID && $0.tabs.contains(where: { $0.id == openerID })
      }), let destination = contexts.values.first(where: { $0.nativeID == nativeID })
    else { return }
    destination.store.perform(.space(space.id))
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
          do { try self.workspace.focusWindow(context.id) } catch { self.report(error) }
        }
      })
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      context.observers.append(
        center.addObserver(forName: name, object: context.window, queue: .main) {
          [weak self, weak context] _ in
          MainActor.assumeIsolated {
            guard let self, let context else { return }
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
    guard let raw = item.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return false }
    if command == .closeTab {
      item.title =
        activeContext?.store.session.selectedSpace.selectedTabID == nil
        ? "Close window" : "Close tab"
    }
    return canPerform(command)
  }

  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: raw)
    else { return }
    perform(command)
  }

  private func installMenus() {
    previousMenu = NSApp.mainMenu
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
      let item = NSMenuItem(title: title, action: #selector(menuAction), keyEquivalent: key)
      item.target = self
      item.representedObject = command.rawValue
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    let app = section("Arcusis Browser")
    add(.quit, "Quit Arcusis Browser", "q", to: app)
    let file = section("File")
    add(.newWindow, "New window", "n", to: file)
    add(.newTab, "New tab", "t", to: file)
    add(.search, "Search or enter address", "l", to: file)
    add(.newSpace, "New space…", "", to: file)
    add(.editSpace, "Edit current space…", "", to: file)
    add(.closeTab, "Close tab", "w", to: file)
    add(.closeWindow, "Close window", "w", to: file, modifiers: [.command, .shift])
    add(.reopenClosed, "Reopen last closed tab", "t", to: file, modifiers: [.command, .shift])
    add(.recentlyClosed, "Recently closed…", "", to: file)
    add(.bookmarkPage, "Bookmark this page", "d", to: file)
    add(.bookmarks, "Bookmarks…", "", to: file)
    add(.history, "History…", "y", to: file)
    add(.downloads, "Downloads", "j", to: file, modifiers: [.command, .shift])
    let edit = section("Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
    }
    edit.addItem(.separator())
    add(.find, "Find in Page…", "f", to: edit)
    add(.findNext, "Find Next", "g", to: edit)
    add(.findPrevious, "Find Previous", "g", to: edit, modifiers: [.command, .shift])
    let tabs = section("Tabs")
    add(.sidebar, "Toggle sidebar", "s", to: tabs)
    add(.nextSpace, "Next space", "]", to: tabs, modifiers: [.control, .option])
    add(.previousSpace, "Previous space", "[", to: tabs, modifiers: [.control, .option])
    add(.reload, "Reload", "r", to: tabs)
    menu = main
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
      let runtime = try ARCChromiumRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace)
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
