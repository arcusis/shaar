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

private struct FillSelection: Equatable {
  let space: UUID
  let profile: UUID
  let tab: UUID?
}

private struct NativeTabPlacement: Equatable {
  let id: UUID
  let pinned: Bool
}

/// Owns one window's live tabs independently of its selected SwiftUI space.
@MainActor @Observable
final class BrowserEngine {
  let runtime: ARCChromiumRuntime
  let events: BrowserRuntimeEvents
  let windowID: String
  private let callbacks: BrowserRuntimeClient
  private(set) var isClosed = false
  var onClosed: ((Bool) -> Void)?
  let downloads = DownloadsModel(folder: DownloadsFolderSource())
  private(set) var pages: [UUID: PageState] = [:]
  private(set) var notice: String?
  private(set) var mediaAccess: [UUID: MediaAccessState] = [:]
  private(set) var extensions: [BrowserExtension] = []
  private(set) var extensionPopupSize = CGSize(width: 480, height: 560)
  let presentsNativePanels: Bool
  let lazyPinnedTabs: Bool
  var extensionPanel: ExtensionPanelRoute? {
    didSet {
      if extensionPanel != nil { passwordFill?.cancel() }
      if extensionPanel == nil { runtime.closeExtensionPopup(forWindowID: windowID) }
    }
  }
  @ObservationIgnored private weak var store: BrowserStore?
  @ObservationIgnored private var loadedProfiles: Set<UUID> = []
  @ObservationIgnored private var loadingProfiles: Set<UUID> = []
  @ObservationIgnored private var failedProfiles: Set<UUID> = []
  @ObservationIgnored fileprivate var liveTabs: Set<UUID> = []
  @ObservationIgnored private var failedTabs: Set<UUID> = []
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private var receivingNativeSelection = false
  @ObservationIgnored private var lastSpaceID: UUID?
  @ObservationIgnored private var lastTabID: UUID?
  @ObservationIgnored private var lastTabOrders: [UUID: [NativeTabPlacement]] = [:]
  private(set) var passwordFill: NativePasswordFillCoordinator?
  private(set) var passwordWindowKey = false
  @ObservationIgnored private weak var fillController: NativeBitwardenController?
  @ObservationIgnored private var fillObserver: UUID?
  @ObservationIgnored private var fillInputMonitor: PasswordFillInputMonitor?
  @ObservationIgnored private var fillSelection: FillSelection?
  private(set) var favicons: [UUID: NSImage] = [:]

  func focusPage(_ tabID: UUID) {
    guard !isClosed, let store, !store.commandIsOpen, store.sheet == nil,
      store.pageFind == nil, store.libraryDrawerSection == nil,
      store.session.selectedPage?.tab.id == tabID,
      runtime.windowID(forTabID: tabID.uuidString) == windowID,
      let view = runtime.view(forTabID: tabID.uuidString), let window = view.window,
      window.isKeyWindow
    else { return }
    runtime.focusTabID(tabID.uuidString)
    window.makeFirstResponder(view)
  }

  func navigateCurrentPage(to url: URL) -> Bool {
    guard !isClosed, let store, let page = store.session.selectedPage,
      let profile = store.session.profileID(forTabID: page.tab.id),
      liveTabs.contains(page.tab.id),
      runtime.windowID(forTabID: page.tab.id.uuidString) == windowID
    else { return false }
    return runtime.navigateTabID(
      page.tab.id.uuidString, profileID: profile.uuidString, windowID: windowID,
      url: url.absoluteString)
  }

  init(
    events: BrowserRuntimeEvents, windowID: String? = nil, store: BrowserStore,
    presentsNativePanels: Bool = true, lazyPinnedTabs: Bool = false
  ) throws {
    let runtime = events.runtime
    self.runtime = runtime
    self.events = events
    self.windowID = windowID ?? runtime.primaryWindowID
    callbacks = BrowserRuntimeClient(windowID: self.windowID) { [weak store] in
      Set(store?.session.profiles.map { $0.id.uuidString } ?? [])
    }
    self.store = store
    self.presentsNativePanels = presentsNativePanels
    self.lazyPinnedTabs = lazyPinnedTabs
    try events.router.register(callbacks)
    store.engine = self
    store.onReloadPage = { [weak self] tab, profile in
      self?.runtime.reloadTabID(tab.uuidString, profileID: profile.uuidString) ?? false
    }
    store.onNavigatePage = { [weak self] tab, profile, url in
      guard let self, !self.isClosed, let store = self.store,
        self.liveTabs.contains(tab),
        self.runtime.windowID(forTabID: tab.uuidString) == self.windowID,
        store.session.profileID(forTabID: tab) == profile,
        store.session.favoritePages.contains(where: { $0.tab.id == tab }),
        self.events.router.client(forTab: tab.uuidString, nativeWindowID: self.windowID)
          === self.callbacks
      else { return false }
      return self.runtime.navigateTabID(
        tab.uuidString, profileID: profile.uuidString, windowID: self.windowID,
        url: url.absoluteString)
    }
    callbacks.onWindowClosed = { [weak self] quitting in
      guard let self else { return }
      for request in self.store?.externalAppRequests ?? [] {
        self.store?.resolveExternalApp(request.id, accepted: false)
      }
      self.detachPasswordFill()
      self.isClosed = true
      self.extensionPanel = nil
      self.store?.dismissPageFind()
      self.liveTabs.removeAll()
      self.pages.removeAll()
      self.mediaAccess.removeAll()
      self.favicons.removeAll()
      self.onClosed?(quitting)
    }
    callbacks.onRendererGone = { [weak self] identity, owner, status, code in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let tab = UUID(uuidString: identity), let profile = UUID(uuidString: owner)
      else { return }
      if self.store?.session.selectedPage?.tab.id == tab { self.passwordFill?.cancel() }
      self.pages[tab]?.loading = false
      self.mediaAccess[tab] = nil
      if case .popup(let popup) = self.extensionPanel, popup.tabID == tab {
        self.extensionPanel = nil
      }
      self.store?.nativeRendererGone(tab, profileID: profile, status: status, exitCode: Int(code))
    }
    callbacks.onDocumentCommitted = { [weak self] identity, owner in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let tab = UUID(uuidString: identity), let profile = UUID(uuidString: owner)
      else {
        return
      }
      if self.store?.session.selectedPage?.tab.id == tab { self.passwordFill?.cancel() }
      self.store?.nativeDocumentCommitted(tab, profileID: profile)
    }
    store.library.onLoad = { [weak self] key, limit, completion in
      guard let self, !self.isClosed else {
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
      guard let self, !self.isClosed else {
        completion("The browser engine is unavailable.")
        return
      }
      let done: @MainActor (Error?) -> Void = { error in completion(error?.localizedDescription) }
      switch mutation {
      case .bookmark(let operation):
        self.events.applyBookmarkOperation(
          operation, profileID: profile.uuidString, completion: done)
      case .deleteHistory(let url):
        self.events.deleteHistoryURL(url, profileID: profile.uuidString, completion: done)
      }
    }
    callbacks.onLibraryChanged = { [weak store] owner, value in
      guard let store, let profile = UUID(uuidString: owner),
        let section = LibrarySection(rawValue: value),
        store.session.profiles.contains(where: { $0.id == profile })
      else { return }
      store.library.invalidate(profile, section: section)
    }
    callbacks.onLibraryError = { [weak store] owner, value, message in
      guard let store, let profile = UUID(uuidString: owner),
        let section = LibrarySection(rawValue: value),
        store.session.profiles.contains(where: { $0.id == profile })
      else { return }
      store.library.serviceFailed(profile, section: section, message: message)
    }
    callbacks.onNotice = { [weak self] message in self?.notice = message }
    downloads.onCommand = { [weak self] action, id, profile, completion in
      guard let self, !self.isClosed else {
        completion("Download controls are unavailable.")
        return
      }
      self.runtime.downloadCommand(action.rawValue, downloadID: id, profileID: profile.uuidString) {
        error in
        MainActor.assumeIsolated { completion(error?.localizedDescription) }
      }
    }
    callbacks.onDownloadChanged = { [weak self] owner, record in
      guard let self, let profile = UUID(uuidString: owner),
        self.store?.session.profiles.contains(where: { $0.id == profile }) == true
      else { return }
      self.downloads.changed(record, profileID: profile)
    }
    callbacks.onDownloadRemoved = { [weak self] owner, id in
      guard let self, let profile = UUID(uuidString: owner) else { return }
      self.downloads.removed(id, profileID: profile)
    }
    callbacks.onDownloadsRestored = { [weak self] owner, rows in
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
    callbacks.onFindResult = { [weak store] identity, token, count, active, final in
      guard let tabID = UUID(uuidString: identity), let requestID = UUID(uuidString: token) else {
        return
      }
      store?.receiveFindResult(
        tabID: tabID, requestID: requestID, count: Int(count), active: Int(active), final: final)
    }
    store.onWebsiteMediaDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveMedia(id, windowID: self.windowID, accepted: accepted)
    }
    callbacks.onWebsiteMediaRequest = { [weak self] payload in self?.requestWebsiteMedia(payload) }
    callbacks.onWebsiteMediaDismissed = { [weak self] id in
      self?.store?.resolveWebsiteMedia(id, accepted: false)
    }
    store.onExternalAppDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveExternalApp(id, windowID: self.windowID, accepted: accepted)
    }
    callbacks.onExternalAppRequest = { [weak self] payload in self?.requestExternalApp(payload) }
    callbacks.onExternalAppDismissed = { [weak self] id in
      self?.store?.resolveExternalApp(id, accepted: false)
    }
    callbacks.onMediaAccess = { [weak self] identity, state in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity)
      else { return }
      self.mediaAccess[id] = MediaAccessState(
        camera: state["camera"]?.boolValue ?? false,
        microphone: state["microphone"]?.boolValue ?? false,
        screen: state["screen"]?.boolValue ?? false)
    }
    store.onInstallDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveInstall(id, windowID: self.windowID, accepted: accepted)
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
    callbacks.onInstallRequest = { [weak self] payload in self?.requestInstallation(payload) }
    callbacks.onExtensionPopup = { [weak self] payload in self?.receivedPopup(payload) }
    callbacks.onExtensionPopupClosed = { [weak self] id in
      guard let self, case .popup(let context) = self.extensionPanel, context.id == id else {
        return
      }
      self.extensionPanel = nil
    }
    callbacks.onExtensionPopupSize = { [weak self] id, size in
      guard let self, case .popup(let context) = self.extensionPanel, context.id == id else {
        return
      }
      self.extensionPopupSize = CGSize(
        width: min(max(size.width, 200), 800),
        height: min(max(size.height, 100), 600))
    }
    fillSelection = currentFillSelection()
    store.onSessionChanged = { [weak self] in
      guard let self else { return }
      let selection = self.currentFillSelection()
      if selection != self.fillSelection {
        self.fillSelection = selection
        self.passwordFill?.cancel()
      }
      self.reconcile()
    }
    store.onCloseTab = { [weak self] id in
      guard let self else { return }
      if self.liveTabs.contains(id) {
        self.runtime.closeTabID(id.uuidString)
      } else {
        self.store?.nativeTabClosed(id)
      }
    }
    callbacks.onTabChanged = { [weak self] identity, address, title, loading, back, forward in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity)
      else { return }
      if loading && self.pages[id]?.loading != true
        && self.store?.session.selectedPage?.tab.id == id
      {
        self.passwordFill?.cancel()
      }
      if loading && self.pages[id]?.loading != true && self.store?.pageFind?.tabID == id {
        self.store?.dismissPageFind()
      }
      self.pages[id] = PageState(loading: loading, canGoBack: back, canGoForward: forward)
      self.store?.nativePageLoading(id, loading: loading)
      if let url = URL(string: address) {
        if let profile = self.store?.session.profileID(forTabID: id),
          self.store?.session.favoritePages.contains(where: { $0.tab.id == id }) == true
        {
          self.store?.nativeFavoritePageChanged(id, profileID: profile, url: url, title: title)
        } else {
          self.store?.nativeTabChanged(id, url: url, title: title)
        }
      }
      if let profile = self.store?.session.profileID(forTabID: id),
        let icon = self.runtime.favicon(
          forTabID: identity, profileID: profile.uuidString, windowID: self.windowID)
      {
        self.favicons[id] = icon
      } else {
        self.favicons[id] = nil
      }
    }
    callbacks.onTabClosed = { [weak self] identity in
      guard let self, let id = UUID(uuidString: identity),
        self.liveTabs.contains(id) || self.pages[id] != nil
      else { return }
      if self.store?.session.selectedPage?.tab.id == id { self.passwordFill?.cancel() }
      self.liveTabs.remove(id)
      self.pages[id] = nil
      self.mediaAccess[id] = nil
      self.favicons[id] = nil
      self.store?.nativeTabClosed(id)
    }
    callbacks.onTabActivated = { [weak self] identity, owner in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity)
      else { return }
      if self.store?.session.selectedPage?.tab.id != id { self.passwordFill?.cancel() }
      guard !self.isClosed, !self.receivingNativeSelection, !self.reconciling,
        self.liveTabs.contains(id), let profile = UUID(uuidString: owner),
        self.store?.session.profileID(forTabID: id) == profile
      else { return }
      self.receivingNativeSelection = true
      if self.store?.session.favoritePages.contains(where: { $0.tab.id == id }) == true {
        _ = self.store?.nativeFavoriteActivated(id, profileID: profile)
      } else {
        _ = self.store?.nativeTabActivated(id, profileID: profile)
      }
      self.receivingNativeSelection = false
      // Chromium is still notifying its tab strip. The model is current before
      // other saves can run, but opening/reordering tabs must wait until it unwinds.
      DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }
    callbacks.onNewTab = { [weak self] identity, owner, address, opener, foreground in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity), let profile = UUID(uuidString: owner),
        let url = URL(string: address.isEmpty ? "about:blank" : address)
      else { return }
      self.liveTabs.insert(id)
      let accepted =
        self.store?.nativeTabOpened(
          BrowserTab(id: id, url: url), profileID: profile,
          openerID: opener.flatMap(UUID.init(uuidString:)), foreground: foreground) ?? false
      if !accepted {
        self.liveTabs.remove(id)
        self.events.router.forgetTab(identity, windowID: self.windowID)
        self.runtime.discardTabID(identity)
      }
    }
  }

  private func currentFillSelection() -> FillSelection? {
    guard let store else { return nil }
    return FillSelection(
      space: store.session.selectedSpaceID,
      profile: store.session.selectedSpace.profileID, tab: store.session.selectedPage?.tab.id)
  }

  static func passwordFillInputAvailable(in store: BrowserStore) -> Bool {
    !store.commandIsOpen && store.sheet == nil && store.libraryDrawerSection == nil
      && store.pageFind == nil
  }

  private func passwordBinding() -> PasswordFillBinding? {
    fillInputMonitor?.arm()
    guard !isClosed, let store, let window = runtime.window(forID: windowID), window.isKeyWindow,
      Self.passwordFillInputAvailable(in: store), extensionPanel == nil,
      let windowUUID = UUID(uuidString: windowID), let tab = store.session.selectedPage?.tab.id,
      store.session.profileID(forTabID: tab) == store.session.selectedSpace.profileID,
      runtime.windowID(forTabID: tab.uuidString) == windowID, liveTabs.contains(tab)
    else { return nil }
    return PasswordFillBinding(
      windowID: windowUUID, profileID: store.session.selectedSpace.profileID, tabID: tab)
  }

  var passwordFillAvailable: Bool {
    _ = passwordWindowKey
    guard let binding = passwordBinding(), let controller = fillController else { return false }
    return runtime.supportsPasswordFill(inWindowID: windowID)
      && controller.fillHandle(profileID: binding.profileID) != nil
  }

  func attachPasswordFill(_ controller: NativeBitwardenController) {
    detachPasswordFill()
    fillController = controller
    let form = NativePasswordFormSession(backend: ChromiumPasswordFormBackend(runtime: runtime)) {
      [weak self] in self?.passwordBinding()
    }
    let coordinator = NativePasswordFillCoordinator(form: form, vault: controller) {
      [weak self] in self?.passwordBinding()
    }
    passwordFill = coordinator
    if let store {
      fillInputMonitor = PasswordFillInputMonitor(store: store) { [weak coordinator] in
        coordinator?.cancel()
      }
      fillInputMonitor?.arm()
    }
    fillObserver = controller.observeFillChanges { [weak coordinator] profile in
      coordinator?.vaultDidChange(profileID: profile)
    }
  }

  func passwordWindowKeyChanged(_ isKey: Bool) {
    passwordWindowKey = isKey
    if !isKey { passwordFill?.cancel() }
  }

  func detachPasswordFill() {
    passwordFill?.cancel()
    if let fillObserver { fillController?.removeFillObserver(fillObserver) }
    fillObserver = nil
    fillInputMonitor = nil
    fillController = nil
    passwordFill = nil
  }

  /// Drop documents before their saved tabs acquire a different engine profile.
  func discardReassignedTabs(_ ids: Set<UUID>) {
    for id in ids {
      failedTabs.remove(id)
      guard liveTabs.remove(id) != nil else { continue }
      events.router.forgetTab(id.uuidString, windowID: windowID)
      pages[id] = nil
      mediaAccess[id] = nil
      favicons[id] = nil
      runtime.discardTabID(id.uuidString)
    }
    passwordFill?.cancel()
  }

  func reconcile() {
    guard !isClosed, !reconciling, !receivingNativeSelection, let store else { return }
    reconciling = true
    defer { reconciling = false }
    let session = store.session
    if lastSpaceID != session.selectedSpaceID || lastTabID != session.selectedPage?.tab.id {
      extensionPanel = nil
      lastSpaceID = session.selectedSpaceID
      lastTabID = session.selectedPage?.tab.id
    }
    let wantedTabs = Set(
      session.spaces.flatMap { $0.tabs.map(\.id) } + session.favoritePages.map { $0.tab.id })
    for removed in liveTabs.subtracting(wantedTabs) {
      // Ordinary tab close waits for Chromium's beforeunload decision. This path
      // handles confirmed space removal; profile files are deliberately retained.
      events.router.forgetTab(removed.uuidString, windowID: windowID)
      runtime.discardTabID(removed.uuidString)
      liveTabs.remove(removed)
      pages[removed] = nil
      mediaAccess[removed] = nil
      favicons[removed] = nil
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
          guard !self.isClosed else { return }
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
                guard let self, !self.isClosed else { return }
                self.runtime.refreshDownloads(forProfileID: profile.uuidString)
              }
            }
          }
          // A cached profile can complete synchronously during reconciliation.
          DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
      }
    }
    for space in session.spaces where loadedProfiles.contains(space.profileID) {
      for tab in space.tabs where !failedTabs.contains(tab.id) {
        let decision = TabMaterializationPolicy.decision(
          isSelected: space.id == session.selectedSpaceID && session.selectedPage?.tab.id == tab.id,
          isLive: liveTabs.contains(tab.id), lazy: lazyPinnedTabs)
        guard decision == .materialize else { continue }
        guard events.router.bindTab(tab.id.uuidString, windowID: windowID) else {
          failedTabs.insert(tab.id)
          notice = "A saved tab already belongs to another window."
          continue
        }
        liveTabs.insert(tab.id)
        do {
          try runtime.openTabID(
            tab.id.uuidString, profileID: space.profileID.uuidString, windowID: windowID,
            url: tab.url.absoluteString)
        } catch {
          events.router.forgetTab(tab.id.uuidString, windowID: windowID)
          liveTabs.remove(tab.id)
          failedTabs.insert(tab.id)
          notice = error.localizedDescription
        }
      }
    }
    let favoritePages = Dictionary(
      uniqueKeysWithValues: session.favoritePages.map { ($0.favoriteID, $0) })
    for favorite in session.favorites where loadedProfiles.contains(favorite.profileID) {
      guard let page = favoritePages[favorite.id], !failedTabs.contains(page.tab.id) else {
        continue
      }
      let decision = TabMaterializationPolicy.decision(
        isSelected: session.selectedSpace.selectedFavoriteID == favorite.id,
        isLive: liveTabs.contains(page.tab.id), lazy: lazyPinnedTabs)
      guard decision == .materialize else { continue }
      guard events.router.bindTab(page.tab.id.uuidString, windowID: windowID) else {
        failedTabs.insert(page.tab.id)
        notice = "A saved Favorite page already belongs to another window."
        continue
      }
      liveTabs.insert(page.tab.id)
      do {
        try runtime.openTabID(
          page.tab.id.uuidString, profileID: favorite.profileID.uuidString, windowID: windowID,
          url: page.tab.url.absoluteString)
      } catch {
        events.router.forgetTab(page.tab.id.uuidString, windowID: windowID)
        liveTabs.remove(page.tab.id)
        failedTabs.insert(page.tab.id)
        notice = error.localizedDescription
      }
    }
    for profile in loadedProfiles {
      let tabs = session.spaces.filter { $0.profileID == profile }.flatMap(\.orderedTabs)
        .filter { liveTabs.contains($0.id) }
      let favoriteTabs = session.favorites.compactMap { favorite -> BrowserTab? in
        guard favorite.profileID == profile, let page = favoritePages[favorite.id],
          liveTabs.contains(page.tab.id)
        else { return nil }
        return page.tab
      }
      let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned } + favoriteTabs
      let positions = ordered.map { NativeTabPlacement(id: $0.id, pinned: $0.isPinned) }
      if lastTabOrders[profile] != positions,
        runtime.placeTabIDs(
          ordered.map { $0.id.uuidString },
          pinnedIDs: ordered.filter(\.isPinned).map { $0.id.uuidString },
          profileID: profile.uuidString, windowID: windowID)
      {
        lastTabOrders[profile] = positions
      }
    }
    runtime.activateProfileID(session.selectedSpace.profileID.uuidString, windowID: windowID)
    if let selected = session.selectedPage?.tab.id {
      runtime.activateTabID(selected.uuidString)
    } else {
      runtime.clearActiveTab(inWindowID: windowID)
    }
    refreshExtensions()
  }

  func refreshExtensions() {
    guard !isClosed, let profile = store?.session.selectedSpace.profileID,
      loadedProfiles.contains(profile)
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

  func reportNotice(_ message: String) { notice = message }

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
      tabID: store.session.selectedPage?.tab.id)
  }

  func executeExtension(_ id: String) {
    guard let tab = store?.session.selectedPage?.tab.id else { return }
    extensionPanel = nil
    do { try runtime.executeExtensionID(id, tabID: tab.uuidString) } catch {
      notice = error.localizedDescription
    }
  }

  private func receivedPopup(_ payload: [String: Any]) {
    guard let store, store.sheet == nil, let id = payload["id"] as? String,
      payload["windowID"] as? String == windowID,
      let profile = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let extensionID = payload["extensionID"] as? String, BrowserExtension.isValidID(extensionID),
      profile == store.session.selectedSpace.profileID,
      tab == store.session.selectedPage?.tab.id
    else {
      if let owner = payload["windowID"] as? String {
        runtime.closeExtensionPopup(forWindowID: owner)
      }
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
    guard payload["windowID"] as? String == windowID else {
      events.resolveInstall(id, windowID: windowID, accepted: false)
      return
    }
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
      events.resolveInstall(id, windowID: windowID, accepted: false)
      notice = "The extension request could not be verified for this page and profile."
      return
    }
  }

  private func requestWebsiteMedia(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String else { return }
    guard payload["windowID"] as? String == windowID else {
      events.resolveMedia(id, windowID: windowID, accepted: false)
      return
    }
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
      events.resolveMedia(id, windowID: windowID, accepted: false)
      notice = "This permission request is unavailable for the current page and profile."
      return
    }
  }

  private func requestExternalApp(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String else { return }
    guard let request = Self.externalAppRequest(from: payload, windowID: windowID),
      let store, request.matches(store.session)
    else {
      events.resolveExternalApp(id, windowID: windowID, accepted: false)
      return
    }
    extensionPanel = nil
    guard store.requestExternalApp(request) else {
      events.resolveExternalApp(id, windowID: windowID, accepted: false)
      return
    }
  }

  static func externalAppRequest(
    from payload: [String: Any], windowID: String
  ) -> ExternalAppRequest? {
    let keys: Set<String> = [
      "id", "profileID", "tabID", "windowID", "pageURL", "scheme", "origin", "app",
    ]
    guard Set(payload.keys) == keys,
      let id = payload["id"] as? String,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let payloadWindowID = payload["windowID"] as? String, payloadWindowID == windowID,
      let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let scheme = payload["scheme"] as? String,
      let rawOrigin = payload["origin"],
      let rawApplicationName = payload["app"]
    else { return nil }

    let origin: URL?
    if rawOrigin is NSNull {
      origin = nil
    } else if let value = rawOrigin as? String, let url = URL(string: value) {
      origin = url
    } else {
      return nil
    }

    let applicationName: String?
    if rawApplicationName is NSNull {
      applicationName = nil
    } else if let value = rawApplicationName as? String {
      applicationName = value
    } else {
      return nil
    }

    return ExternalAppRequest(
      id: id, profileID: profileID, tabID: tabID, pageURL: pageURL, scheme: scheme,
      requestingOrigin: origin, applicationName: applicationName, windowID: windowID)
  }
}

struct ChromiumPage: NSViewRepresentable {
  let engine: BrowserEngine
  let tabID: UUID

  func makeNSView(context: Context) -> ChromiumPageContainerView {
    ChromiumPageContainerView()
  }

  func updateNSView(_ container: ChromiumPageContainerView, context: Context) {
    if container.select(
      engine.runtime.view(forTabID: tabID.uuidString), tabID: tabID, liveTabs: engine.liveTabs),
      container.window?.isKeyWindow == true
    {
      engine.focusPage(tabID)
    }
  }

  static func dismantleNSView(_ view: ChromiumPageContainerView, coordinator: ()) {
    view.attach(nil)
  }
}

final class ChromiumPageContainerView: NSView {
  private(set) weak var pageView: NSView?
  private var retainedPages: [UUID: NSView] = [:]

  @discardableResult
  func select(_ page: NSView?, tabID: UUID, liveTabs: Set<UUID>) -> Bool {
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    for id in retainedPages.keys.filter({ !liveTabs.contains($0) }) {
      if let view = retainedPages.removeValue(forKey: id), view.superview === self {
        view.removeFromSuperview()
      }
    }
    guard let page else { return attach(nil) }
    let changed = pageView !== page || page.superview !== self
    for view in retainedPages.values where view.superview === self {
      view.isHidden = view !== page
    }
    if let previous = retainedPages.updateValue(page, forKey: tabID), previous !== page,
      previous.superview === self
    {
      previous.removeFromSuperview()
    }
    pageView = page
    if page.superview !== self {
      page.removeFromSuperview()
      page.translatesAutoresizingMaskIntoConstraints = true
      page.frame = bounds
      page.autoresizingMask = [.width, .height]
      addSubview(page)
    }
    page.isHidden = false
    layoutSubtreeIfNeeded()
    return changed
  }

  @discardableResult
  func attach(_ page: NSView?) -> Bool {
    if page == nil {
      for view in retainedPages.values where view.superview === self { view.removeFromSuperview() }
      retainedPages.removeAll()
    }
    if pageView === page, page?.superview === self { return false }
    if let pageView, pageView !== page, pageView.superview === self {
      pageView.removeFromSuperview()
    }
    pageView = page
    if let page {
      if page.superview !== self {
        page.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
      }
      layoutSubtreeIfNeeded()
    }
    return true
  }

  override func layout() {
    super.layout()
    if let pageView, pageView.superview === self, pageView.frame != bounds {
      pageView.frame = bounds
    }
  }
}
