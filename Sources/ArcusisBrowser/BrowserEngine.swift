// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

/// Owns one window's live tabs independently of its selected SwiftUI space.
@MainActor @Observable
final class BrowserEngine {
  static let extensionInstallRefreshDelaysMilliseconds = [250, 750, 1_500, 3_000, 4_500]
  let runtime: ARCChromiumRuntime
  let events: BrowserRuntimeEvents
  let downloadDirectoryApplier: ProfileDownloadDirectoryApplier?
  let windowID: String
  private let callbacks: BrowserRuntimeClient
  let autoPictureInPicture: AutoPictureInPicture
  let pictureInPictureEnterGate = PictureInPictureEnterGate()
  let pictureInPictureControls = PictureInPictureControls()
  private(set) var isClosed = false
  var onClosed: ((Bool) -> Void)?
  var onNativeWindowLost: (() -> Void)?
  var inspectors: [UUID: InspectorModel] = [:]
  var developerModels: [UUID: DeveloperPageModel] = [:]
  var developmentPages: [UUID: DevelopmentPage] = [:]
  var developmentPageURLs: [UUID: URL] = [:]
  var developmentProbedURLs: [UUID: URL] = [:]
  var developmentProbeRequests: [UUID: UUID] = [:]
  let downloads: DownloadsModel
  private(set) var pages: [UUID: PageState] = [:]
  private(set) var notice: String?
  private(set) var mediaAccess: [UUID: MediaAccessState] = [:]
  private(set) var extensions: [BrowserExtension] = []
  private(set) var extensionPopupSize = CGSize(width: 480, height: 560)
  let presentsNativePanels: Bool
  let lazyPinnedTabs: Bool
  var extensionPanel: ExtensionPanelRoute? {
    didSet {
      if extensionPanel == nil { runtime.closeExtensionPopup(forWindowID: windowID) }
    }
  }
  @ObservationIgnored private(set) weak var store: BrowserStore?
  @ObservationIgnored private var loadedProfiles: Set<UUID> = []
  @ObservationIgnored private var loadingProfiles: Set<UUID> = []
  @ObservationIgnored private var failedProfiles: Set<UUID> = []
  @ObservationIgnored var liveTabs: Set<UUID> = []
  /// Tabs whose close call is on the stack.
  @ObservationIgnored private var closesInFlight: Set<UUID> = []
  /// Reassigned tabs must wait for Chromium to release their old profile ownership.
  @ObservationIgnored private var tabsAwaitingProfileReassignment: Set<UUID> = []
  /// Tabs moved from another window stay in the workspace while Chromium closes the old owner.
  @ObservationIgnored private var tabsAwaitingWindowTransfer: Set<UUID> = []
  @ObservationIgnored private var failedTabs: Set<UUID> = []
  /// Crashed documents whose native reload failed before the close event arrived.
  @ObservationIgnored private var tabsAwaitingReload: Set<UUID> = []
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private var receivingNativeSelection = false
  @ObservationIgnored private var lastSpaceID: UUID?
  @ObservationIgnored private var lastTabID: UUID?
  @ObservationIgnored private var lastTabOrders: [UUID: [NativeTabPlacement]] = [:]
  @ObservationIgnored let sleepingTabs = SleepingTabScheduler()
  @ObservationIgnored var memoryPressureSource: DispatchSourceMemoryPressure?
  @ObservationIgnored var suspensionTask: Task<Void, Never>?
  @ObservationIgnored private var delayedRefreshTasks: [UUID: Task<Void, Never>] = [:]
  private(set) var favicons: [UUID: NSImage] = [:]
  /// Site host last associated with each tab's icon. An empty query for that host
  /// leaves the icon in place. A different host drops the live icon and the saved file.
  @ObservationIgnored private var faviconHosts: [UUID: String] = [:]
  /// Last image written for a tab. Loading ticks update the live icon without changing this,
  /// so the bitmap compare still sees the saved icon when the page finishes loading.
  @ObservationIgnored private var persistedFaviconImages: [UUID: NSImage] = [:]

  isolated deinit {
    suspensionTask?.cancel()
    memoryPressureSource?.cancel()
    delayedRefreshTasks.values.forEach { $0.cancel() }
  }

  func seedFavicon(_ image: NSImage, for tabID: UUID) {
    favicons[tabID] = image
  }

  /// Records the icon Chromium returned for this document host.
  /// The live icon updates immediately. A pinned tab or Favorite is saved only after loading
  /// finishes, and only when that saved image changed.
  func noteDocumentFavicon(
    _ icon: NSImage?, for tabID: UUID, host: String?, loading: Bool = false
  ) {
    let documentHost = host?.lowercased()
    if let icon {
      favicons[tabID] = icon
      guard !loading else { return }
      let persist =
        store?.isPrivate != true && store?.remembersFavicon(forTab: tabID) == true
      if persist, savedIconChanged(icon, for: tabID, host: documentHost) {
        persistedFaviconImages[tabID] = icon
        store?.rememberFavicon(icon, forTab: tabID, host: documentHost)
      }
      faviconHosts[tabID] = documentHost
      return
    }
    // A loading tick, or a tick that names no site, is not a different site.
    guard !loading, let documentHost, !documentHost.isEmpty else { return }
    let previous = faviconHosts[tabID] ?? store?.faviconHost(forTab: tabID)
    guard let previous else {
      faviconHosts[tabID] = documentHost
      return
    }
    guard previous != documentHost else {
      faviconHosts[tabID] = documentHost
      return
    }
    clearFavicon(tabID)
    faviconHosts[tabID] = documentHost
    store?.forgetFavicon(forTab: tabID)
  }

  /// Compares against the last image written for this site. Callers check the pin or Favorite
  /// gate first, so an ordinary tab never pays for the bitmap compare.
  private func savedIconChanged(_ icon: NSImage, for tabID: UUID, host: String?) -> Bool {
    guard faviconHosts[tabID] == host, let saved = persistedFaviconImages[tabID] else {
      return true
    }
    return !FaviconCache.sameImage(saved, icon)
  }

  private func clearFavicon(_ id: UUID) {
    favicons[id] = nil
    faviconHosts[id] = nil
    persistedFaviconImages[id] = nil
  }

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

  @discardableResult
  func performPageZoomAction(_ action: String, tabID: UUID) -> Bool {
    guard !isClosed, let store, let page = store.session.selectedPage,
      page.tab.id == tabID,
      runtime.windowID(forTabID: page.tab.id.uuidString) == windowID,
      let profileID = store.session.profileID(forTabID: page.tab.id)
    else { return false }
    return runtime.performPageZoomAction(
      action, tabID: page.tab.id.uuidString, profileID: profileID.uuidString)
  }

  init(
    events: BrowserRuntimeEvents, windowID: String? = nil, store: BrowserStore,
    presentsNativePanels: Bool = true, lazyPinnedTabs: Bool = false,
    downloadDirectoryApplier: ProfileDownloadDirectoryApplier? = nil
  ) throws {
    let runtime = events.runtime
    self.runtime = runtime
    notice = runtime.startupNotice
    self.events = events
    self.downloadDirectoryApplier = downloadDirectoryApplier
    self.windowID = windowID ?? runtime.primaryWindowID
    autoPictureInPicture = AutoPictureInPicture(
      engine: .chromium(runtime, gate: pictureInPictureEnterGate))
    callbacks = BrowserRuntimeClient(windowID: self.windowID) { [weak store] in
      Set(store?.session.profiles.map { $0.id.uuidString } ?? [])
    }
    self.store = store
    downloads = DownloadsModel(profileDirectory: { [weak runtime, weak store] profileID in
      store?.preferences.downloadDirectory(for: profileID)
        ?? runtime?.downloadsDirectory(forProfileID: profileID.uuidString)
    })
    self.presentsNativePanels = presentsNativePanels
    self.lazyPinnedTabs = lazyPinnedTabs
    try events.router.register(callbacks)
    store.engine = self
    store.onReloadPage = { [weak self] tab, profile, mode in
      self?.reloadPage(tab, profile: profile, mode: mode) ?? false
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
      self.isClosed = true
      self.suspensionTask?.cancel()
      self.memoryPressureSource?.cancel()
      self.memoryPressureSource = nil
      self.cancelDelayedRefreshes()
      for model in self.inspectors.values where model.isOpen { model.close() }
      self.inspectors.removeAll()
      for model in self.developerModels.values { model.close() }
      self.developerModels.removeAll()
      self.developmentPages.removeAll()
      self.developmentPageURLs.removeAll()
      self.developmentProbedURLs.removeAll()
      self.developmentProbeRequests.removeAll()
      self.extensionPanel = nil
      self.store?.dismissPageFind()
      self.liveTabs.removeAll()
      self.pages.removeAll()
      self.mediaAccess.removeAll()
      self.store?.media.removeAll()
      self.autoPictureInPicture.forgetAll()
      self.pictureInPictureControls.detach()
      self.favicons.removeAll()
      self.onClosed?(quitting)
    }
    callbacks.onRendererGone = { [weak self] identity, owner, status, code in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let tab = UUID(uuidString: identity), let profile = UUID(uuidString: owner)
      else { return }
      // Closing the document can report the renderer exiting with it.
      // The close request stays in force and a saved pin archives.
      if self.closesInFlight.contains(tab) { return }
      self.pages[tab]?.loading = false
      self.mediaAccess[tab] = nil
      self.forgetMedia(tab)
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
      self.store?.nativeDocumentCommitted(tab, profileID: profile)
      if let model = self.developerModels[tab] {
        model.update(target: model.target, committed: true)
      }
      if let inspector = self.inspectors[tab] {
        inspector.documentChanged(url: inspector.target.url, committed: true)
      }
    }
    callbacks.onAgentBridgeStatus = { [weak self] identity, owner, payload in
      guard let self, let tab = UUID(uuidString: identity),
        let profile = UUID(uuidString: owner),
        self.store?.session.profileID(forTabID: tab) == profile,
        self.runtime.windowID(forTabID: identity) == self.windowID,
        let enabled = payload["enabled"] as? Bool,
        let count = payload["connectionCount"] as? Int
      else { return }
      self.developerModels[tab]?.agentBridge.receive(enabled: enabled, connectionCount: count)
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
        completion(PanelsL10n.string("The browser engine is unavailable."))
        return
      }
      let done: @MainActor (Error?) -> Void = { error in
        completion(
          error == nil ? nil : PanelsL10n.string("Could not update the Library. Try again."))
      }
      switch mutation {
      case .bookmark(let operation):
        self.events.applyBookmarkOperation(
          operation, profileID: profile.uuidString, completion: done)
      case .bookmarks(let operations):
        self.applyImportedBookmarks(operations, profileID: profile, completion: done)
      case .deleteHistory(let url):
        self.events.deleteHistoryURL(url, profileID: profile.uuidString, completion: done)
      case .importHistory(let source, let rows):
        self.runtime.importHistoryRows(
          rows, source: source.rawValue, profileID: profile.uuidString, completion: done)
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
        completion(PanelsL10n.string("Download controls are unavailable."))
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
      self.clearRecoveredDownloadListNotice()
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
    store.onWebsitePermissionDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveMedia(id, windowID: self.windowID, accepted: accepted)
    }
    store.onDesktopCaptureDecision = { [weak self] id, sourceID in
      guard let self else { return }
      self.events.resolveDesktopCapture(id, windowID: self.windowID, sourceID: sourceID)
    }
    store.onWebShareDecision = { [weak self] id, outcome in
      guard let self else { return }
      self.events.resolveWebShare(id, windowID: self.windowID, outcome: outcome)
    }
    store.onPrintDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolvePrint(id, windowID: self.windowID, accepted: accepted)
    }
    store.onJavaScriptDialogDecision = { [weak self] id, accepted, input in
      self?.events.resolveJavaScriptDialog(id, accepted: accepted, input: input)
    }
    callbacks.onDesktopCaptureRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let request = DesktopCaptureRequest(payload: payload),
        let store = self.store, store.requestDesktopCapture(request)
      else {
        self.events.resolveDesktopCapture(id, windowID: self.windowID, sourceID: nil)
        return
      }
    }
    callbacks.onDesktopCaptureDismissed = { [weak store] id in
      store?.dismissDesktopCapture(id)
    }
    callbacks.onWebShareRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let request = WebShareRequest(payload: payload), let store = self.store else {
        self.events.resolveWebShare(id, windowID: self.windowID, outcome: .cancelled)
        return
      }
      store.rememberPermissionFrame(
        request.tabID, frameID: request.frameID, origin: request.requestingOrigin)
      guard store.requestWebShare(request)
      else {
        self.events.resolveWebShare(id, windowID: self.windowID, outcome: .cancelled)
        return
      }
    }
    callbacks.onPrintRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let request = PrintRequest(payload: payload), let store = self.store else {
        self.events.resolvePrint(id, windowID: self.windowID, accepted: false)
        return
      }
      store.rememberPermissionFrame(
        request.tabID, frameID: request.frameID, origin: request.requestingOrigin)
      guard store.requestPrint(request) else {
        store.forgetPermissionFrame(request.tabID, matching: request.frameID)
        self.events.resolvePrint(id, windowID: self.windowID, accepted: false)
        return
      }
    }
    callbacks.onJavaScriptDialogRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String,
        let request = JavaScriptDialogRequest(payload: payload), let store = self.store
      else {
        if let id = payload["id"] as? String {
          self?.runtime.resolveJavaScriptDialogRequestID(id, accepted: false, input: nil)
        }
        return
      }
      guard store.requestJavaScriptDialog(request) else {
        self.runtime.resolveJavaScriptDialogRequestID(id, accepted: false, input: nil)
        return
      }
    }
    callbacks.onJavaScriptDialogDismissed = { [weak store] id in
      store?.dismissJavaScriptDialog(id)
    }
    callbacks.onWebsiteMediaRequest = { [weak self] payload in
      self?.requestWebsitePermission(payload)
    }
    callbacks.onWebsiteMediaDismissed = { [weak self] id in
      self?.store?.resolveWebsitePermission(id, accepted: false)
    }
    store.onExternalAppDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveExternalApp(id, windowID: self.windowID, accepted: accepted)
    }
    store.onDeviceChooserDecision = { [weak self] request, index in
      self?.settleDeviceChooser(request, optionIndex: index)
    }
    store.onHTTPAuthDecision = { [weak self] request, username, password in
      self?.events.resolveHTTPAuth(request, username: username, password: password)
    }
    callbacks.onDeviceChooserEvent = { [weak self] payload in
      self?.receiveDeviceChooser(payload)
    }
    callbacks.onHTTPAuthRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let request = HTTPAuthRequest(payload: payload),
        let store = self.store, store.requestHTTPAuth(request)
      else {
        if let tabID = payload["tabID"] as? String {
          self.events.rejectHTTPAuth(id, tabID: tabID,
                                     windowID: payload["windowID"] as? String ?? "")
        }
        return
      }
    }
    callbacks.onHTTPAuthDismissed = { [weak store] id in store?.dismissHTTPAuth(id) }
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
    callbacks.onMediaSessionChanged = { [weak self] identity, payload in
      self?.receiveMediaSession(identity, payload: payload)
    }
    store.onMediaCommand = { [weak self] tab, command in
      self?.performMedia(command, tabID: tab) ?? false
    }
    callbacks.onPictureInPictureChanged = { [weak self] identity, active in
      self?.receivePictureInPicture(identity, active: active)
    }
    pictureInPictureControls.onCommand = { [weak self] tab, command in
      self?.performPictureInPicture(command, tabID: tab)
    }
    callbacks.onTabActivationRequest = { [weak self] identity, _ in
      self?.showRequestedTab(identity)
    }
    store.onAutomaticPictureInPictureChanged = { [weak self] site, profile in
      self?.applyAutomaticPictureInPicture(site: site, profileID: profile)
    }
    store.onInstallDecision = { [weak self] id, accepted in
      guard let self else { return }
      self.events.resolveInstall(id, windowID: self.windowID, accepted: accepted)
      if accepted {
        self.scheduleDelayedRefreshes(after: Self.extensionInstallRefreshDelaysMilliseconds) {
          [weak self] in
          guard let self else { return }
          self.refreshExtensions()
          ExtensionManagerModel.refreshInstalled()
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
    store.onSessionChanged = { [weak self] in
      self?.reconcile()
    }
    store.onCloseTab = { [weak self] id in
      guard let self else { return }
      if self.liveTabs.contains(id) {
        self.closesInFlight.insert(id)
        self.runtime.closeTabID(id.uuidString)
        self.closesInFlight.remove(id)
      } else {
        self.store?.nativeTabClosed(id)
      }
    }
    callbacks.onTabChanged = { [weak self] identity, address, title, loading, back, forward in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity),
        let ownerProfile = self.runtime.profileID(forTabID: identity),
        let profile = self.store?.session.profileID(forTabID: id),
        ownerProfile == profile.uuidString
      else { return }
      let document = URL(string: address)
      let documentHost = document?.host?.lowercased()
      let startedLoading = loading && self.pages[id]?.loading != true
      if startedLoading && self.store?.pageFind?.tabID == id {
        self.store?.dismissPageFind()
      }
      self.pages[id] = PageState(loading: loading, canGoBack: back, canGoForward: forward)
      self.store?.nativePageLoading(id, loading: loading)
      if let url = document {
        self.inspectors[id]?.documentChanged(url: url)
        self.developerDocumentChanged(id, url: url)
        self.updateDevelopmentPage(tabID: id, url: url, loading: loading)
        if let profile = self.store?.session.profileID(forTabID: id),
          self.store?.session.favoritePages.contains(where: { $0.tab.id == id }) == true
        {
          self.store?.nativeFavoritePageChanged(id, profileID: profile, url: url, title: title)
        } else {
          self.store?.nativeTabChanged(id, url: url, title: title)
        }
        self.withholdAutomaticPictureInPictureIfOff(id, url: url)
      }
      var icon: NSImage?
      if let profile = self.store?.session.profileID(forTabID: id) {
        icon = self.runtime.favicon(
          forTabID: identity, profileID: profile.uuidString, windowID: self.windowID)
      }
      self.noteDocumentFavicon(icon, for: id, host: documentHost, loading: loading)
    }
    callbacks.onTabLifecycle = { [weak self] identity, state, audible, capturing in
      guard let self, let id = UUID(uuidString: identity), let store = self.store else { return }
      self.sleepingTabs.apply(
        state: state, audible: audible, capturing: capturing, id: id, store: store)
    }
    callbacks.onTabClosed = { [weak self] identity, closedWindowID in
      guard let self, closedWindowID == self.windowID,
        self.runtime.windowID(forTabID: identity) == nil,
        self.events.router.tabOwnerWindowID(for: identity) == nil,
        let id = UUID(uuidString: identity)
      else { return }
      self.store?.dismissHTTPAuth(forTabID: id)
      if self.tabsAwaitingProfileReassignment.remove(id) != nil {
        self.pages[id] = nil
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
        return
      }
      self.sleepingTabs.forget(id)
      self.store?.noteTabAwake(id)
      guard self.liveTabs.contains(id) || self.pages[id] != nil else { return }
      self.liveTabs.remove(id)
      self.pages[id] = nil
      if let inspector = self.inspectors.removeValue(forKey: id), inspector.isOpen {
        inspector.close()
      }
      self.developerModels.removeValue(forKey: id)?.close()
      self.developmentPages[id] = nil
      self.developmentPageURLs[id] = nil
      self.developmentProbedURLs[id] = nil
      self.developmentProbeRequests[id] = nil
      self.mediaAccess[id] = nil
      self.forgetMedia(id)
      self.clearFavicon(id)
      self.store?.nativeTabClosed(id)
      if let store = self.store, store.session.page(forTabID: id)?.tab.isPinned == true,
        let profile = store.session.profileID(forTabID: id)
      {
        // Wait for Reload instead of immediately recreating a failing renderer
        // inside its close callback (or repeatedly during reconciliation).
        self.failedTabs.insert(id)
        self.lastTabOrders[profile] = nil
        store.nativeRendererGone(id, profileID: profile, status: "native_tab_closed", exitCode: 0)
      }
      self.scheduleReloadRecreation(id)
    }
    callbacks.onTabActivated = { [weak self] identity, owner in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity)
      else { return }
      guard !self.isClosed, !self.receivingNativeSelection, !self.reconciling,
        self.liveTabs.contains(id), let profile = UUID(uuidString: owner),
        self.store?.session.profileID(forTabID: id) == profile
      else { return }
      // Reconciliation requests activation, whose acknowledgment comes back here.
      // An already-selected tab must not start another reconcile/activate cycle.
      if self.store?.session.selectedPage?.tab.id == id {
        self.restoreSelectedPageAfterActivation(id)
        return
      }
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
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID else { return }
      guard let id = UUID(uuidString: identity), let profile = UUID(uuidString: owner),
        let url = URL(string: address.isEmpty ? "about:blank" : address)
      else {
        self.runtime.discardTabID(identity)
        return
      }
      self.liveTabs.insert(id)
      let accepted =
        self.store?.nativeTabOpened(
          BrowserTab(id: id, url: url), profileID: profile,
          openerID: opener.flatMap(UUID.init(uuidString:)), foreground: foreground) ?? false
      if !accepted {
        self.liveTabs.remove(id)
        self.runtime.discardTabID(identity)
      }
    }
    suspensionTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, !self.isClosed else { return }
        self.suspendInactiveTabs()
      }
    }
    startSleepingTabWatch()
  }

  /// Drop documents before their saved tabs acquire a different engine profile.
  func discardReassignedTabs(_ ids: Set<UUID>) {
    for id in ids {
      failedTabs.remove(id)
      sleepingTabs.forget(id)
      store?.noteTabAwake(id)
      guard liveTabs.remove(id) != nil else { continue }
      tabsAwaitingProfileReassignment.insert(id)
      pages[id] = nil
      if let inspector = inspectors.removeValue(forKey: id), inspector.isOpen { inspector.close() }
      developerModels.removeValue(forKey: id)?.close()
      mediaAccess[id] = nil
      forgetMedia(id)
      clearFavicon(id)
      runtime.discardTabID(id.uuidString)
      waitForProfileReassignmentClose(id)
    }
  }

  private func waitForProfileReassignmentClose(_ id: UUID) {
    Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard let self, !self.isClosed,
          self.tabsAwaitingProfileReassignment.contains(id)
        else { return }
        if self.runtime.windowID(forTabID: id.uuidString) == nil,
          self.events.router.tabOwnerWindowID(for: id.uuidString) == nil
        {
          self.tabsAwaitingProfileReassignment.remove(id)
          self.reconcile()
          return
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
      guard let self, self.tabsAwaitingProfileReassignment.remove(id) != nil else { return }
      self.failedTabs.insert(id)
      self.notice = ShellL10n.string(
        "This tab could not be reopened after its profile changed.")
    }
  }

  private func waitForTransferredTabRelease(_ id: UUID) {
    guard tabsAwaitingWindowTransfer.insert(id).inserted else { return }
    Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard let self, !self.isClosed,
          self.tabsAwaitingWindowTransfer.contains(id)
        else { return }
        if self.runtime.windowID(forTabID: id.uuidString) == nil,
          self.events.router.tabOwnerWindowID(for: id.uuidString) == nil
        {
          self.tabsAwaitingWindowTransfer.remove(id)
          self.openReleasedTransferredTab(id)
          self.reconcile()
          return
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
      guard let self, self.tabsAwaitingWindowTransfer.remove(id) != nil else { return }
      self.failedTabs.insert(id)
      self.notice = ShellL10n.string("This tab could not be moved to this window.")
    }
  }

  private func openReleasedTransferredTab(_ id: UUID) {
    guard !isClosed, let store,
      let page = store.session.page(forTabID: id),
      case .tab(let tab) = page,
      let profile = store.session.profileID(forTabID: id),
      loadedProfiles.contains(profile), !liveTabs.contains(id)
    else { return }
    guard events.router.bindTab(id.uuidString, windowID: windowID) else {
      failedTabs.insert(id)
      notice = ShellL10n.string("A saved tab already belongs to another window.")
      return
    }
    liveTabs.insert(id)
    do {
      try runtime.openTabID(
        id.uuidString, profileID: profile.uuidString, windowID: windowID,
        url: tab.url.absoluteString)
    } catch {
      events.router.forgetTab(id.uuidString, windowID: windowID)
      liveTabs.remove(id)
      failedTabs.insert(id)
      notice = ShellL10n.string("This tab could not be opened. Try reloading it.")
    }
  }

  private func reloadPage(_ tab: UUID, profile: UUID, mode: PageReloadMode) -> Bool {
    guard !isClosed, !runtime.isQuitting, store?.session.profileID(forTabID: tab) == profile
    else { return false }
    guard ensureLiveWindow() else { return false }
    if liveTabs.contains(tab) {
      if runtime.reloadTabID(
        tab.uuidString, profileID: profile.uuidString, mode: mode.engineMode)
      {
        return true
      }
      // WebContentsDestroyed unbinds the document immediately and posts the
      // closed event later. Reload in that gap still sees a live tab and the
      // native call fails. Recreate once the close event drops the stale target.
      guard store?.rendererFailures[tab] != nil else { return false }
      return recreateAfterRejectedReload(tab)
    }
    return openRetainedDocument(tab, profile: profile)
  }

  private func recreateAfterRejectedReload(_ tab: UUID) -> Bool {
    tabsAwaitingReload.insert(tab)
    runtime.closeTabID(tab.uuidString)
    return true
  }

  private func scheduleReloadRecreation(_ tab: UUID) {
    guard tabsAwaitingReload.remove(tab) != nil else { return }
    Task { @MainActor [weak self] in
      self?.openReplacementDocument(tab)
    }
  }

  private func openReplacementDocument(_ tab: UUID) {
    guard !isClosed, let profile = store?.session.profileID(forTabID: tab) else { return }
    _ = openRetainedDocument(tab, profile: profile)
  }

  private func openRetainedDocument(_ tab: UUID, profile: UUID) -> Bool {
    // A failed open or destroyed WebContents has no native target to reload.
    // Materialize the retained session entry again with its original identity.
    failedTabs.remove(tab)
    failedProfiles.remove(profile)
    reconcile()
    return liveTabs.contains(tab) || loadingProfiles.contains(profile)
  }

  func reconcile() {
    guard !isClosed, !runtime.isQuitting, !reconciling, !receivingNativeSelection, let store
    else { return }
    guard ensureLiveWindow() else { return }
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
      sleepingTabs.forget(removed)
      store.noteTabAwake(removed)
      runtime.discardTabID(removed.uuidString)
      liveTabs.remove(removed)
      pages[removed] = nil
      if let inspector = inspectors.removeValue(forKey: removed), inspector.isOpen {
        inspector.close()
      }
      developerModels.removeValue(forKey: removed)?.close()
      developmentPages[removed] = nil
      developmentPageURLs[removed] = nil
      developmentProbedURLs[removed] = nil
      developmentProbeRequests[removed] = nil
      mediaAccess[removed] = nil
      forgetMedia(removed)
      clearFavicon(removed)
    }
    for profile in Set(session.spaces.map(\.profileID)) {
      guard !loadedProfiles.contains(profile), !loadingProfiles.contains(profile),
        !failedProfiles.contains(profile)
      else { continue }
      loadingProfiles.insert(profile)
      runtime.loadProfileID(
        profile, httpsOnly: store.preferences.httpsOnlyChoice(for: profile)
      ) { [weak self] error in
        Task { @MainActor [weak self] in
          await self?.finishLoadingProfile(profile, error: error)
        }
      }
    }
    for space in session.spaces where loadedProfiles.contains(space.profileID) {
      for tab in space.tabs where !failedTabs.contains(tab.id) {
        guard !tabsAwaitingProfileReassignment.contains(tab.id) else { continue }
        let nativeOwner = runtime.windowID(forTabID: tab.id.uuidString)
        let routedOwner = events.router.tabOwnerWindowID(for: tab.id.uuidString)
        if (nativeOwner != nil && nativeOwner != windowID)
          || (routedOwner != nil && routedOwner != windowID)
        {
          waitForTransferredTabRelease(tab.id)
          continue
        }
        let decision = TabMaterializationPolicy.decision(
          isSelected: space.id == session.selectedSpaceID
            && (session.selectedPage?.tab.id == tab.id
              || store.selectedSplit?.tabIDs.contains(tab.id) == true),
          isLive: liveTabs.contains(tab.id),
          lazy: lazyPinnedTabs,
          keepAlive: tab.keepAlive)
        guard decision == .materialize else { continue }
        guard events.router.bindTab(tab.id.uuidString, windowID: windowID) else {
          failedTabs.insert(tab.id)
          notice = ShellL10n.string("A saved tab already belongs to another window.")
          continue
        }
        liveTabs.insert(tab.id)
        do {
          try runtime.openTabID(
            tab.id.uuidString, profileID: space.profileID.uuidString, windowID: windowID,
            url: tab.url.absoluteString)
        } catch {
          if recoverMissingWindow() { return }
          events.router.forgetTab(tab.id.uuidString, windowID: windowID)
          liveTabs.remove(tab.id)
          failedTabs.insert(tab.id)
          notice = ShellL10n.string("This tab could not be opened. Try reloading it.")
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
        isLive: liveTabs.contains(page.tab.id),
        lazy: lazyPinnedTabs,
        keepAlive: page.tab.keepAlive)
      guard decision == .materialize else { continue }
      guard events.router.bindTab(page.tab.id.uuidString, windowID: windowID) else {
        failedTabs.insert(page.tab.id)
        notice = ShellL10n.string("A saved Favorite page already belongs to another window.")
        continue
      }
      liveTabs.insert(page.tab.id)
      do {
        try runtime.openTabID(
          page.tab.id.uuidString, profileID: favorite.profileID.uuidString, windowID: windowID,
          url: page.tab.url.absoluteString)
      } catch {
        if recoverMissingWindow() { return }
        events.router.forgetTab(page.tab.id.uuidString, windowID: windowID)
        liveTabs.remove(page.tab.id)
        failedTabs.insert(page.tab.id)
        notice = ShellL10n.string("This tab could not be opened. Try reloading it.")
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
      let ordered = Self.orderedTabs(tabs, favorites: favoriteTabs)
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
    // Ask for picture-in-picture before the leaving tab is hidden. YouTube pauses
    // on hide, and a paused video is skipped. The enter reply, or a short fallback,
    // activates the next tab. A switch that is not leaving a playing video does not wait.
    pictureInPictureEnterGate.startSwitch()
    handOffPictureInPicture()
    let waitingToHidePlayingVideo = pictureInPictureEnterGate.deferActivationIfRequested {
      [weak self] in
      self?.activateReconciledSelection()
    }
    if waitingToHidePlayingVideo { return }
    activateReconciledSelection()
  }

  static func orderedTabs(_ tabs: [BrowserTab], favorites: [BrowserTab]) -> [BrowserTab] {
    let partition = tabs.reduce(into: (pinned: [BrowserTab](), unpinned: [BrowserTab]())) {
      if $1.isPinned { $0.pinned.append($1) } else { $0.unpinned.append($1) }
    }
    return partition.pinned + partition.unpinned + favorites
  }

  /// Selects the current page. Picture-in-picture may defer this until the page
  /// has been asked to enter, so a second switch cannot run inside the first one.
  private func activateReconciledSelection() {
    guard !isClosed, !runtime.isQuitting, let session = store?.session else { return }
    let alreadyReconciling = reconciling
    reconciling = true
    defer { reconciling = alreadyReconciling }
    runtime.activateProfileID(session.selectedSpace.profileID.uuidString, windowID: windowID)
    if let selected = session.selectedPage?.tab.id {
      wakeIfSleeping(selected)
      runtime.activateTabID(selected.uuidString)
      // Chromium can move the active WebContents to its own BrowserView while
      // processing native activation. Restore the page after that queued call.
      restoreSelectedPageAfterActivation(selected)
    } else {
      runtime.clearActiveTab(inWindowID: windowID)
    }
    refreshExtensions()
  }

  private func ensureLiveWindow() -> Bool {
    guard runtime.isWindowOpenID(windowID) else {
      nativeWindowLost()
      return false
    }
    return true
  }

  private func recoverMissingWindow() -> Bool {
    guard !runtime.isWindowOpenID(windowID) else { return false }
    nativeWindowLost()
    return true
  }

  private func nativeWindowLost() {
    if let onNativeWindowLost {
      onNativeWindowLost()
    } else {
      runtime.retireClosedWindowID(windowID)
      events.windowClosed(windowID, quitting: false)
    }
  }

  private func restoreSelectedPageAfterActivation(_ selected: UUID) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isClosed,
        self.store?.session.selectedPage?.tab.id == selected,
        self.runtime.windowID(forTabID: selected.uuidString) == self.windowID,
        let view = self.runtime.view(forTabID: selected.uuidString),
        let window = self.runtime.window(forID: self.windowID)
      else { return }
      _ = ChromiumPageContainerView.restoreSelectedPage(view, tabID: selected, in: window)
    }
  }

  private func finishLoadingProfile(_ profile: UUID, error: Error?) async {
    loadingProfiles.remove(profile)
    guard !isClosed else { return }
    if let error {
      failedProfiles.insert(profile)
      notice = error.localizedDescription
    } else {
      do {
        if let directory = store?.preferences.downloadDirectory(for: profile),
          let downloadDirectoryApplier
        {
          do {
            let acknowledged = try await downloadDirectoryApplier(profile, directory)
            if store?.preferences.downloadDirectory(for: profile) == directory {
              guard let acknowledged else { throw CocoaError(.fileWriteUnknown) }
              recordDownloadDirectoryAcknowledgement(
                acknowledged, requested: directory, for: profile)
            }
          } catch {
            if store?.preferences.downloadDirectory(for: profile) == directory { throw error }
          }
        }
        loadedProfiles.insert(profile)
        store?.library.refresh(profile, section: .bookmarks)
        store?.library.refresh(profile, section: .history)
        // Download history initializes asynchronously and can return an empty early list.
        scheduleDelayedRefreshes(after: [300, 700, 2_000]) { [weak self] in
          guard let self else { return }
          self.runtime.refreshDownloads(forProfileID: profile.uuidString)
        }
      } catch {
        failedProfiles.insert(profile)
        notice = error.localizedDescription
      }
    }
    DispatchQueue.main.async { [weak self] in self?.reconcile() }
  }

  var pendingDelayedRefreshTaskCount: Int { delayedRefreshTasks.count }

  func scheduleDelayedRefreshes(
    after delays: [Int], action: @escaping @MainActor () -> Void
  ) {
    let id = UUID()
    delayedRefreshTasks[id] = Task { @MainActor [weak self] in
      defer { self?.delayedRefreshTasks[id] = nil }
      for delay in delays {
        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
        guard let self, !self.isClosed else { return }
        action()
      }
    }
  }

  private func cancelDelayedRefreshes() {
    let tasks = Array(delayedRefreshTasks.values)
    delayedRefreshTasks.removeAll()
    tasks.forEach { $0.cancel() }
  }

  func recordDownloadDirectoryAcknowledgement(_ acknowledged: URL, requested: URL, for profile: UUID) {
    guard store?.preferences.downloadDirectory(for: profile) == requested else { return }
    store?.preferences.setDownloadDirectory(acknowledged, for: profile)
  }

  func refreshExtensions() {
    guard !isClosed, let profile = store?.session.selectedSpace.profileID,
      ExtensionManagementOperation.isValidProfileID(profile.uuidString),
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

  /// Matches the exhausted download-list notice from ChromiumEngineServices.
  static let downloadListUnavailableNotice = "Downloads could not be restored."

  func reportNotice(_ message: String) { notice = message }

  private func clearRecoveredDownloadListNotice() {
    guard notice == Self.downloadListUnavailableNotice else { return }
    notice = nil
  }

  func revealDownload(_ id: String, profileID: UUID, open: Bool) {
    guard let selected = store?.session.selectedSpace.profileID, selected == profileID else {
      return
    }
    guard
      let candidate = downloads.fileToOpen(
        id: id, profileID: profileID, selectedProfileID: selected),
      let directory = runtime.downloadsDirectory(forProfileID: profileID.uuidString),
      let url = Self.validatedDownloadURL(candidate, in: directory)
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

  static func validatedDownloadURL(_ candidate: URL, in directory: URL) -> URL? {
    guard candidate.isFileURL, directory.isFileURL else { return nil }
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let file = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"),
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true
    else { return nil }
    return file
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
      notice = PanelsL10n.string("Could not run the extension. Try again.")
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
        name: extensions.first { $0.id == extensionID }?.name ?? ShellL10n.string("Extension")))
  }

  private func requestInstallation(_ payload: [String: Any]) {
    guard let id = payload["requestId"] as? String else { return }
    let permissions = payload["permissions"] as? [String]
    let hostPermissions = payload["hostPermissions"] as? [String]
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
      permissions?.allSatisfy({ $0.utf8.count <= 8192 }) != false,
      let kind = (payload["type"] as? String).flatMap(ExtensionInstallKind.init(rawValue:)),
      hostPermissions?.allSatisfy({ $0.utf8.count <= 8192 }) != false,
      let browserExtension = BrowserExtension(id: extensionID, name: name, version: version),
      let request = ExtensionInstallRequest(
        id: id, profileID: profile, tabID: tab, sourceURL: source,
        browserExtension: browserExtension, kind: kind,
        permissions: ExtensionConsentPermissions.displayValues(
          permissions: permissions ?? [], hostPermissions: hostPermissions,
          complete: permissions != nil && payload["permissionsComplete"] as? Bool == true)),
      store.requestInstallation(request)
    else {
      events.resolveInstall(id, windowID: windowID, accepted: false)
      notice = ShellL10n.string(
        "The extension request could not be verified for this page and profile.")
      return
    }
  }

  private func requestWebsitePermission(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String else { return }
    guard let store else {
      events.resolveMedia(id, windowID: windowID, accepted: false)
      return
    }
    extensionPanel = nil
    let knownTabs = Set(
      store.session.spaces.flatMap(\.tabs).map(\.id) + store.session.favoritePages.map(\.tab.id))
    let outstanding = Set(store.websitePermissionRequests.map(\.id))
    let request: WebsitePermissionRequest
    switch WebsitePermissionEvent.intake(
      from: payload, windowID: windowID, outstandingIDs: outstanding, knownTabs: knownTabs)
    {
    case .ignoreDuplicate:
      return
    case .deny:
      events.resolveMedia(id, windowID: windowID, accepted: false)
      notice = ShellL10n.string(
        "This permission request is unavailable for the current page and profile.")
      return
    case .show(let shown):
      request = shown
    }
    if let frameID = request.frameID {
      store.rememberPermissionFrame(
        request.tabID, frameID: frameID, origin: request.requestingOrigin)
    }
    guard store.requestWebsitePermission(request) else {
      store.forgetPermissionFrame(request.tabID, matching: request.frameID)
      events.resolveMedia(id, windowID: windowID, accepted: false)
      notice = ShellL10n.string(
        "This permission request is unavailable for the current page and profile.")
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

  private func applyImportedBookmarks(
    _ operations: [[String: Any]], profileID: UUID,
    completion: @escaping @MainActor (Error?) -> Void
  ) {
    BrowserImport.apply(
      operations,
      using: { [weak self] operation, done in
        guard let self else {
          done(LibraryDataError.invalidBookmarks)
          return
        }
        self.events.applyBookmarkOperation(
          operation, profileID: profileID.uuidString, completion: done)
      }, completion: completion)
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
