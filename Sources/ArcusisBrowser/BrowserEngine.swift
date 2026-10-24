import AppKit
import BrowserCore
import ChromiumBridge
import Observation
import SwiftUI

struct PageState: Equatable {
  var loading: Bool
  var canGoBack: Bool
  var canGoForward: Bool
}

struct MediaAccessState: Equatable {
  let camera: Bool
  let microphone: Bool
  let screen: Bool
  var isCapturing: Bool { camera || microphone || screen }
}

private struct NativeTabPlacement: Equatable {
  let id: UUID
  let pinned: Bool
}

/// Owns live native tabs independently of the selected SwiftUI space.
@MainActor @Observable
final class BrowserEngine {
  let runtime: ARCChromiumRuntime
  let downloads = DownloadsModel()
  private(set) var pages: [UUID: PageState] = [:]
  private(set) var notice: String?
  private(set) var mediaAccess: [UUID: MediaAccessState] = [:]
  private(set) var extensions: [BrowserExtension] = []
  private(set) var extensionPopupSize = CGSize(width: 480, height: 560)
  let presentsNativePanels: Bool
  var extensionPanel: ExtensionPanelRoute? {
    didSet {
      if extensionPanel == nil { runtime.closeExtensionPopup() }
    }
  }
  @ObservationIgnored private weak var store: BrowserStore?
  @ObservationIgnored private var loadedProfiles: Set<UUID> = []
  @ObservationIgnored private var loadingProfiles: Set<UUID> = []
  @ObservationIgnored private var failedProfiles: Set<UUID> = []
  @ObservationIgnored private var liveTabs: Set<UUID> = []
  @ObservationIgnored private var failedTabs: Set<UUID> = []
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private var lastSpaceID: UUID?
  @ObservationIgnored private var lastTabID: UUID?
  @ObservationIgnored private var lastTabOrders: [UUID: [NativeTabPlacement]] = [:]

  init(runtime: ARCChromiumRuntime, store: BrowserStore, presentsNativePanels: Bool = true) {
    self.runtime = runtime
    self.store = store
    self.presentsNativePanels = presentsNativePanels
    store.engine = self
    store.library.onLoad = { [weak self] key, limit, completion in
      guard let self else {
        completion(.failure(LibraryDataError.invalidBookmarks))
        return
      }
      switch key.section {
      case .bookmarks:
        self.runtime.bookmarks(forProfileID: key.profileID.uuidString) { value, error in
          if let error {
            completion(.failure(error))
          } else if let value {
            completion(.success(value))
          } else {
            completion(.failure(LibraryDataError.invalidBookmarks))
          }
        }
      case .history:
        self.runtime.history(forProfileID: key.profileID.uuidString, limit: limit) { value, error in
          if let error {
            completion(.failure(error))
          } else if let value {
            completion(.success(value))
          } else {
            completion(.failure(LibraryDataError.invalidHistory))
          }
        }
      }
    }
    store.library.onMutation = { [weak self] profile, mutation, completion in
      guard let self else {
        completion("The browser engine is unavailable.")
        return
      }
      let done: @MainActor (Error?) -> Void = { error in completion(error?.localizedDescription) }
      switch mutation {
      case .bookmark(let operation):
        self.runtime.applyBookmarkOperation(
          operation, profileID: profile.uuidString, completion: done)
      case .deleteHistory(let url):
        self.runtime.deleteHistoryURL(url, profileID: profile.uuidString, completion: done)
      }
    }
    runtime.onLibraryChanged = { [weak store] owner, value in
      guard let store, let profile = UUID(uuidString: owner),
        let section = LibrarySection(rawValue: value),
        store.session.profiles.contains(where: { $0.id == profile })
      else { return }
      store.library.invalidate(profile, section: section)
    }
    runtime.onLibraryError = { [weak store] owner, value, message in
      guard let store, let profile = UUID(uuidString: owner),
        let section = LibrarySection(rawValue: value),
        store.session.profiles.contains(where: { $0.id == profile })
      else { return }
      store.library.serviceFailed(profile, section: section, message: message)
    }
    runtime.onNotice = { [weak self] message in self?.notice = message }
    downloads.onCommand = { [weak self] action, id, profile, completion in
      guard let self else {
        completion("Download controls are unavailable.")
        return
      }
      self.runtime.downloadCommand(action.rawValue, downloadID: id, profileID: profile.uuidString) {
        error in
        MainActor.assumeIsolated { completion(error?.localizedDescription) }
      }
    }
    runtime.onDownloadChanged = { [weak self] owner, record in
      guard let self, let profile = UUID(uuidString: owner),
        self.store?.session.profiles.contains(where: { $0.id == profile }) == true
      else { return }
      self.downloads.changed(record, profileID: profile)
    }
    runtime.onDownloadRemoved = { [weak self] owner, id in
      guard let self, let profile = UUID(uuidString: owner) else { return }
      self.downloads.removed(id, profileID: profile)
    }
    runtime.onDownloadsRestored = { [weak self] owner, rows in
      guard let self, let profile = UUID(uuidString: owner),
        self.store?.session.profiles.contains(where: { $0.id == profile }) == true
      else { return }
      self.downloads.restore(rows, profileID: profile)
    }
    store.onFindRequest = { [weak self] request, forward in
      self?.runtime.find(
        inTabID: request.tabID.uuidString, profileID: request.profileID.uuidString,
        requestID: request.requestID.uuidString, text: request.query, forward: forward) ?? false
    }
    store.onStopFinding = { [weak self] tabID in
      self?.runtime.stopFinding(inTabID: tabID.uuidString)
    }
    runtime.onFindResult = { [weak store] identity, token, count, active, final in
      guard let tabID = UUID(uuidString: identity), let requestID = UUID(uuidString: token) else {
        return
      }
      store?.receiveFindResult(
        tabID: tabID, requestID: requestID, count: Int(count), active: Int(active), final: final)
    }
    store.onWebsiteMediaDecision = { [weak self] id, accepted in
      self?.runtime.resolveWebsiteMediaRequestID(id, accepted: accepted)
    }
    runtime.onWebsiteMediaRequest = { [weak self] payload in self?.requestWebsiteMedia(payload) }
    runtime.onWebsiteMediaDismissed = { [weak self] id in
      self?.store?.resolveWebsiteMedia(id, accepted: false)
    }
    runtime.onMediaAccess = { [weak self] identity, state in
      guard let self, let id = UUID(uuidString: identity) else { return }
      self.mediaAccess[id] = MediaAccessState(
        camera: state["camera"]?.boolValue ?? false,
        microphone: state["microphone"]?.boolValue ?? false,
        screen: state["screen"]?.boolValue ?? false)
    }
    store.onInstallDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.runtime.resolveInstallRequestID(id, accepted: accepted)
      if accepted {
        Task { [weak self] in
          for _ in 0..<20 {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.refreshExtensions()
          }
        }
      }
    }
    runtime.onInstallRequest = { [weak self] payload in self?.requestInstallation(payload) }
    runtime.onExtensionPopup = { [weak self] payload in self?.receivedPopup(payload) }
    runtime.onExtensionPopupClosed = { [weak self] id in
      guard let self, case .popup(let context) = self.extensionPanel, context.id == id else {
        return
      }
      self.extensionPanel = nil
    }
    runtime.onExtensionPopupSize = { [weak self] id, size in
      guard let self, case .popup(let context) = self.extensionPanel, context.id == id else {
        return
      }
      self.extensionPopupSize = CGSize(
        width: min(max(size.width, 200), 800),
        height: min(max(size.height, 100), 600))
    }
    store.onSessionChanged = { [weak self] in self?.reconcile() }
    store.onCloseTab = { [weak self] id in
      guard let self else { return }
      if self.liveTabs.contains(id) {
        self.runtime.closeTabID(id.uuidString)
      } else {
        self.store?.nativeTabClosed(id)
      }
    }
    runtime.onTabChanged = { [weak self] identity, address, title, loading, back, forward in
      guard let self, let id = UUID(uuidString: identity) else { return }
      if loading && self.pages[id]?.loading != true && self.store?.pageFind?.tabID == id {
        self.store?.dismissPageFind()
      }
      self.pages[id] = PageState(loading: loading, canGoBack: back, canGoForward: forward)
      if let url = URL(string: address) { self.store?.nativeTabChanged(id, url: url, title: title) }
    }
    runtime.onTabClosed = { [weak self] identity in
      guard let self, let id = UUID(uuidString: identity) else { return }
      self.liveTabs.remove(id)
      self.pages[id] = nil
      self.mediaAccess[id] = nil
      self.store?.nativeTabClosed(id)
    }
    runtime.onNewTab = { [weak self] identity, owner, address, opener, foreground in
      guard let self, let id = UUID(uuidString: identity), let profile = UUID(uuidString: owner),
        let url = URL(string: address.isEmpty ? "about:blank" : address)
      else { return }
      self.liveTabs.insert(id)
      let accepted =
        self.store?.nativeTabOpened(
          BrowserTab(id: id, url: url), profileID: profile,
          openerID: opener.flatMap(UUID.init(uuidString:)), foreground: foreground) ?? false
      if !accepted { self.runtime.discardTabID(identity) }
    }
  }

  func reconcile() {
    guard !reconciling, let store else { return }
    reconciling = true
    defer { reconciling = false }
    let session = store.session
    if lastSpaceID != session.selectedSpaceID || lastTabID != session.selectedSpace.selectedTabID {
      extensionPanel = nil
      lastSpaceID = session.selectedSpaceID
      lastTabID = session.selectedSpace.selectedTabID
    }
    let wantedTabs = Set(session.spaces.flatMap { $0.tabs.map(\.id) })
    for removed in liveTabs.subtracting(wantedTabs) {
      // Ordinary tab close waits for Chromium's beforeunload decision. This path
      // handles confirmed space removal; profile files are deliberately retained.
      runtime.discardTabID(removed.uuidString)
      liveTabs.remove(removed)
      pages[removed] = nil
      mediaAccess[removed] = nil
    }
    for profile in Set(session.spaces.map(\.profileID)) {
      guard !loadedProfiles.contains(profile), !loadingProfiles.contains(profile),
        !failedProfiles.contains(profile)
      else { continue }
      loadingProfiles.insert(profile)
      runtime.loadProfileID(profile.uuidString) { [weak self] error in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.loadingProfiles.remove(profile)
          if let error {
            self.failedProfiles.insert(profile)
            self.notice = error.localizedDescription
          } else {
            self.loadedProfiles.insert(profile)
            self.store?.library.refresh(profile, section: .bookmarks)
            self.store?.library.refresh(profile, section: .history)
            // Chromium's download history initializes asynchronously after profile load.
            Task { [weak self] in
              for delay in [300, 700, 2000] {
                try? await Task.sleep(for: .milliseconds(delay))
                self?.runtime.refreshDownloads(forProfileID: profile.uuidString)
              }
            }
          }
          // A cached profile can complete synchronously during reconciliation.
          DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
      }
    }
    for space in session.spaces where loadedProfiles.contains(space.profileID) {
      for tab in space.tabs where !liveTabs.contains(tab.id) && !failedTabs.contains(tab.id) {
        liveTabs.insert(tab.id)
        do {
          try runtime.openTabID(
            tab.id.uuidString, profileID: space.profileID.uuidString, url: tab.url.absoluteString)
        } catch {
          liveTabs.remove(tab.id)
          failedTabs.insert(tab.id)
          notice = error.localizedDescription
        }
      }
    }
    for profile in loadedProfiles {
      let tabs = session.spaces.filter { $0.profileID == profile }.flatMap(\.orderedTabs)
        .filter { liveTabs.contains($0.id) }
      let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
      let positions = ordered.map { NativeTabPlacement(id: $0.id, pinned: $0.isPinned) }
      if lastTabOrders[profile] != positions,
        runtime.placeTabIDs(
          ordered.map { $0.id.uuidString },
          pinnedIDs: ordered.filter(\.isPinned).map { $0.id.uuidString },
          profileID: profile.uuidString)
      {
        lastTabOrders[profile] = positions
      }
    }
    runtime.activateProfileID(session.selectedSpace.profileID.uuidString)
    if let selected = session.selectedSpace.selectedTabID {
      runtime.activateTabID(selected.uuidString)
    } else {
      runtime.clearActiveTab()
    }
    refreshExtensions()
  }

  func refreshExtensions() {
    guard let profile = store?.session.selectedSpace.profileID, loadedProfiles.contains(profile)
    else {
      extensions = []
      return
    }
    extensions = runtime.extensions(forProfileID: profile.uuidString).compactMap { record in
      guard let id = record["id"] as? String, let name = record["name"] as? String,
        let version = record["version"] as? String
      else { return nil }
      return BrowserExtension(id: id, name: name, version: version)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func revealDownload(_ id: String, profileID: UUID, open: Bool) {
    guard let selected = store?.session.selectedSpace.profileID,
      let url = downloads.fileToOpen(id: id, profileID: profileID, selectedProfileID: selected)
    else { return }
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true
    else {
      downloads.fileActionFailed(profileID: profileID)
      return
    }
    if open {
      if !NSWorkspace.shared.open(url) { downloads.fileActionFailed(profileID: profileID) }
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func showExtensionList() {
    guard let store, store.sheet == nil else { return }
    extensionPanel = nil
    store.dismissCommand()
    refreshExtensions()
    extensionPanel = .list(
      profileID: store.session.selectedSpace.profileID,
      tabID: store.session.selectedSpace.selectedTabID)
  }

  func executeExtension(_ id: String) {
    guard let tab = store?.session.selectedSpace.selectedTabID else { return }
    extensionPanel = nil
    do { try runtime.executeExtensionID(id, tabID: tab.uuidString) } catch {
      notice = error.localizedDescription
    }
  }

  private func receivedPopup(_ payload: [String: Any]) {
    guard let store, store.sheet == nil, let id = payload["id"] as? String,
      let profile = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let extensionID = payload["extensionID"] as? String, BrowserExtension.isValidID(extensionID),
      profile == store.session.selectedSpace.profileID,
      tab == store.session.selectedSpace.selectedTabID
    else {
      runtime.closeExtensionPopup()
      return
    }
    extensionPopupSize = CGSize(width: 480, height: 560)
    extensionPanel = .popup(
      ExtensionPopupContext(
        id: id, profileID: profile, tabID: tab, extensionID: extensionID,
        name: extensions.first { $0.id == extensionID }?.name ?? "Extension"))
  }

  private func requestInstallation(_ payload: [String: Any]) {
    guard let id = payload["requestId"] as? String else { return }
    extensionPanel = nil
    guard let store,
      let profile = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let source = (payload["sourceURL"] as? String).flatMap(URL.init(string:)),
      let extensionID = payload["id"] as? String, let name = payload["name"] as? String,
      let version = payload["version"] as? String,
      let permissions = payload["permissions"] as? [String],
      let kind = (payload["type"] as? String).flatMap(ExtensionInstallKind.init(rawValue:)),
      let browserExtension = BrowserExtension(id: extensionID, name: name, version: version),
      let request = ExtensionInstallRequest(
        id: id, profileID: profile, tabID: tab, sourceURL: source,
        browserExtension: browserExtension, kind: kind, permissions: permissions),
      store.requestInstallation(request)
    else {
      runtime.resolveInstallRequestID(id, accepted: false)
      notice = "The extension request could not be verified for this page and profile."
      return
    }
  }

  private func requestWebsiteMedia(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String else { return }
    extensionPanel = nil
    guard let store,
      let profile = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let page = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let origin = (payload["origin"] as? String).flatMap(URL.init(string:)),
      let rawKinds = payload["permissions"] as? [String],
      rawKinds.allSatisfy({ WebsiteMediaKind(rawValue: $0) != nil }),
      let request = WebsiteMediaRequest(
        id: id, profileID: profile, tabID: tab,
        pageURL: page, requestingOrigin: origin,
        kinds: rawKinds.compactMap(WebsiteMediaKind.init(rawValue:))),
      store.requestWebsiteMedia(request)
    else {
      runtime.resolveWebsiteMediaRequestID(id, accepted: false)
      notice = "This permission request is unavailable for the current page and profile."
      return
    }
  }
}

struct ChromiumPage: NSViewRepresentable {
  let engine: BrowserEngine
  let tabID: UUID

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    guard let page = engine.runtime.view(forTabID: tabID.uuidString) else { return }
    if page.superview !== container {
      for child in container.subviews { child.removeFromSuperview() }
      page.removeFromSuperview()
      page.frame = container.bounds
      page.autoresizingMask = [.width, .height]
      container.addSubview(page)
      if container.window?.isKeyWindow == true { engine.runtime.focusTabID(tabID.uuidString) }
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    // Detach the view only. The engine keeps the tab, profile, and page alive.
    for child in view.subviews { child.removeFromSuperview() }
  }
}

/// Chromium owns the AppKit loop; SwiftUI renders the chrome inside its native window.
@MainActor
final class NativeBrowserHost: NSObject, NSMenuItemValidation {
  private let store: BrowserStore
  private let engine: BrowserEngine

  init(runtime: ARCChromiumRuntime, store: BrowserStore) {
    self.store = store
    engine = BrowserEngine(runtime: runtime, store: store)
    super.init()
  }

  static func run(frameworkURL: URL) -> Int32 {
    do {
      let directory = URL.applicationSupportDirectory
        .appending(path: "Arcusis Browser/Chromium", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let runtime = try ARCChromiumRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(runtime: runtime, store: .persistent())
      runtime.onReady = { [weak host] in host?.start() }
      return withExtendedLifetime(host) {
        runtime.run(withDataDirectory: directory, testing: false)
      }
    } catch {
      FileHandle.standardError.write(
        Data("Browser startup failed: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func start() {
    guard let window = engine.runtime.window, let content = engine.runtime.hostView else { return }
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    content.addSubview(host)
    window.title = "Arcusis Browser"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.minSize = NSSize(width: 760, height: 520)
    installMenus()
    engine.reconcile()
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func installMenus() {
    let main = NSMenu()
    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let result = NSMenu(title: title)
      item.submenu = result
      main.addItem(item)
      return result
    }
    func add(
      _ title: String, _ action: Selector, _ key: String, to menu: NSMenu,
      modifiers: NSEvent.ModifierFlags = .command
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    let app = menu("Arcusis Browser")
    add("Quit Arcusis Browser", #selector(quit), "q", to: app)
    let file = menu("File")
    add("New tab", #selector(search), "t", to: file)
    add("Search or enter address", #selector(search), "l", to: file)
    add("New space…", #selector(newSpace), "", to: file)
    add("Edit current space…", #selector(editSpace), "", to: file)
    add("Close tab", #selector(closeTab), "w", to: file)
    add(
      "Reopen last closed tab", #selector(reopenClosedTab), "t", to: file,
      modifiers: [.command, .shift])
    add("Recently closed…", #selector(showRecentlyClosed), "", to: file)
    add("Bookmark this page", #selector(bookmarkPage), "d", to: file)
    add("Bookmarks…", #selector(showBookmarks), "", to: file)
    add("History…", #selector(showHistory), "y", to: file)
    add("Downloads", #selector(showDownloads), "j", to: file, modifiers: [.command, .shift])
    let edit = menu("Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
    }
    edit.addItem(.separator())
    add("Find in Page…", #selector(findInPage), "f", to: edit)
    add("Find Next", #selector(findNext), "g", to: edit)
    add("Find Previous", #selector(findPrevious), "g", to: edit, modifiers: [.command, .shift])
    let tabs = menu("Tabs")
    add("Toggle sidebar", #selector(toggleSidebar), "s", to: tabs)
    add("Next space", #selector(nextSpace), "]", to: tabs, modifiers: [.control, .option])
    add("Previous space", #selector(previousSpace), "[", to: tabs, modifiers: [.control, .option])
    add("Reload", #selector(reload), "r", to: tabs)
    NSApp.mainMenu = main
  }

  @objc private func search() { store.showCommand() }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(findInPage):
      return store.sheet == nil && store.session.selectedSpace.selectedTabID != nil
    case #selector(findNext), #selector(findPrevious): return store.pageFind?.canMove == true
    case #selector(showDownloads): return store.sheet == nil
    case #selector(reopenClosedTab): return store.canReopenClosedTab
    case #selector(showRecentlyClosed): return store.sheet == nil
    case #selector(bookmarkPage): return store.canBookmarkCurrentPage
    case #selector(showBookmarks), #selector(showHistory): return store.sheet == nil
    default: return true
    }
  }
  @objc private func findInPage() { store.showPageFind() }
  @objc private func findNext() { store.movePageFind(forward: true) }
  @objc private func findPrevious() { store.movePageFind(forward: false) }
  @objc private func showDownloads() { store.showDownloads() }
  @objc private func reopenClosedTab() { store.reopenLastClosedTab() }
  @objc private func showRecentlyClosed() { store.showRecentlyClosed() }
  @objc private func bookmarkPage() { store.bookmarkCurrentPage() }
  @objc private func showBookmarks() { store.showLibrary(.bookmarks) }
  @objc private func showHistory() { store.showLibrary(.history) }
  @objc private func newSpace() { store.spaceEditor = .create }
  @objc private func editSpace() { store.spaceEditor = .edit(store.session.selectedSpaceID) }
  @objc private func closeTab() {
    if let id = store.session.selectedSpace.selectedTabID { store.closeTab(id) }
  }
  @objc private func toggleSidebar() { store.sidebarIsVisible.toggle() }
  @objc private func nextSpace() { store.cycleSpace(by: 1) }
  @objc private func previousSpace() { store.cycleSpace(by: -1) }
  @objc private func reload() {
    if let id = store.session.selectedSpace.selectedTabID {
      engine.runtime.reloadTabID(id.uuidString)
    }
  }
  @objc private func quit() { engine.runtime.quit() }
}
