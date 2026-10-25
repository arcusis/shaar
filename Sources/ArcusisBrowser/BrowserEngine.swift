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
  let runtime: ARCChromiumRuntime
  let events: BrowserRuntimeEvents
  let windowID: String
  private let callbacks: BrowserRuntimeClient
  private(set) var isClosed = false
  var onClosed: ((Bool) -> Void)?
  let downloads = DownloadsModel()
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
  @ObservationIgnored private weak var store: BrowserStore?
  @ObservationIgnored private var loadedProfiles: Set<UUID> = []
  @ObservationIgnored private var loadingProfiles: Set<UUID> = []
  @ObservationIgnored private var failedProfiles: Set<UUID> = []
  @ObservationIgnored private var liveTabs: Set<UUID> = []
  @ObservationIgnored private var failedTabs: Set<UUID> = []
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private var receivingNativeSelection = false
  @ObservationIgnored private var lastSpaceID: UUID?
  @ObservationIgnored private var lastTabID: UUID?
  @ObservationIgnored private var lastTabOrders: [UUID: [NativeTabPlacement]] = [:]

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
    callbacks.onWindowClosed = { [weak self] quitting in
      guard let self else { return }
      self.isClosed = true
      self.extensionPanel = nil
      self.store?.dismissPageFind()
      self.liveTabs.removeAll()
      self.pages.removeAll()
      self.mediaAccess.removeAll()
      self.onClosed?(quitting)
    }
    callbacks.onRendererGone = { [weak self] identity, owner, status, code in
      guard let self, self.runtime.windowID(forTabID: identity) == self.windowID,
        let tab = UUID(uuidString: identity), let profile = UUID(uuidString: owner)
      else { return }
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
    store.onSessionChanged = { [weak self] in self?.reconcile() }
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
      if loading && self.pages[id]?.loading != true && self.store?.pageFind?.tabID == id {
        self.store?.dismissPageFind()
      }
      self.pages[id] = PageState(loading: loading, canGoBack: back, canGoForward: forward)
      self.store?.nativePageLoading(id, loading: loading)
      if let url = URL(string: address) { self.store?.nativeTabChanged(id, url: url, title: title) }
    }
    callbacks.onTabClosed = { [weak self] identity in
      guard let self, let id = UUID(uuidString: identity),
        self.liveTabs.contains(id) || self.pages[id] != nil
      else { return }
      self.liveTabs.remove(id)
      self.pages[id] = nil
      self.mediaAccess[id] = nil
      self.store?.nativeTabClosed(id)
    }
    callbacks.onTabActivated = { [weak self] identity, owner in
      guard let self, !self.isClosed, !self.receivingNativeSelection, !self.reconciling,
        self.runtime.windowID(forTabID: identity) == self.windowID,
        let id = UUID(uuidString: identity), self.liveTabs.contains(id),
        let profile = UUID(uuidString: owner)
      else { return }
      self.receivingNativeSelection = true
      self.store?.nativeTabActivated(id, profileID: profile)
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

  func reconcile() {
    guard !isClosed, !reconciling, !receivingNativeSelection, let store else { return }
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
      events.router.forgetTab(removed.uuidString, windowID: windowID)
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
          isSelected: space.id == session.selectedSpaceID && space.selectedTabID == tab.id,
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
    for profile in loadedProfiles {
      let tabs = session.spaces.filter { $0.profileID == profile }.flatMap(\.orderedTabs)
        .filter { liveTabs.contains($0.id) }
      let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
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
    if let selected = session.selectedSpace.selectedTabID {
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
      payload["windowID"] as? String == windowID,
      let profile = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let extensionID = payload["extensionID"] as? String, BrowserExtension.isValidID(extensionID),
      profile == store.session.selectedSpace.profileID,
      tab == store.session.selectedSpace.selectedTabID
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
