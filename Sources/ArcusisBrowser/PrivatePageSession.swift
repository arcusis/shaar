// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Observation
import SwiftUI

struct PrivateBrowserTab: Identifiable, Equatable {
  let id: String
  var url: String
  var title: String
  var loading: Bool
  var canGoBack: Bool
  var canGoForward: Bool
}

/// Connects the normal browser model to Chromium's off-the-record tab API.
@MainActor @Observable
final class PrivatePageSession {
  let runtime: ARCChromiumRuntime
  let contextID: String
  let windowID: String
  private(set) var pages: [UUID: PageState] = [:]
  private(set) var failure: String?
  private(set) var pendingHTTP: URL?
  @ObservationIgnored private var pendingHTTPTabID: UUID?
  @ObservationIgnored private var approvedHTTP: Set<UUID> = []
  @ObservationIgnored private(set) weak var store: BrowserStore?
  @ObservationIgnored private var liveTabs: Set<UUID>
  @ObservationIgnored private var reconciling = false
  @ObservationIgnored private var selectedTabID: UUID?
  @ObservationIgnored var onEmpty: (() -> Void)?

  init(
    runtime: ARCChromiumRuntime, contextID: String, windowID: String,
    firstTabID: UUID, store: BrowserStore
  ) {
    self.runtime = runtime
    self.contextID = contextID
    self.windowID = windowID
    self.store = store
    liveTabs = [firstTabID]
    selectedTabID = firstTabID
    store.privatePage = self
    store.onSessionChanged = { [weak self] in self?.reconcile() }
    store.onCloseTab = { [weak self] id in self?.close(id) }
    store.onReloadPage = { [weak self] id, _, mode in self?.reload(id, mode: mode) ?? false }
    store.onNavigatePage = { [weak self] id, _, url in self?.navigate(id, to: url) ?? false }
    store.onFindRequest = { [weak self] request, forward in
      guard let self else { return false }
      return self.runtime.find(
        inPrivateTabID: request.tabID.uuidString, windowID: self.windowID,
        contextID: self.contextID, requestID: request.requestID.uuidString,
        text: request.query, forward: forward)
    }
    store.onStopFinding = { [weak self] tabID in
      guard let self else { return }
      self.runtime.stopFinding(
        inPrivateTabID: tabID.uuidString, windowID: self.windowID, contextID: self.contextID)
    }
  }

  var selectedState: PageState? {
    store?.session.selectedPage.flatMap { pages[$0.tab.id] }
  }

  func reconcile() {
    guard !reconciling, let store else { return }
    reconciling = true
    defer { reconciling = false }
    let tabs = store.session.spaces.flatMap(\.tabs) + store.session.favoritePages.map(\.tab)
    let expected = Set(tabs.map(\.id))
    for tab in tabs where !liveTabs.contains(tab.id) {
      guard allow(tab.url, for: tab.id) else { continue }
      do {
        try runtime.openPrivateTabID(
          tab.id.uuidString, windowID: windowID,
          contextID: contextID, url: tab.url.absoluteString)
        liveTabs.insert(tab.id)
      } catch {
        failure = error.localizedDescription
      }
    }
    for id in liveTabs.subtracting(expected) { close(id) }
    if let selected = store.session.selectedPage?.tab.id,
      selected != selectedTabID, liveTabs.contains(selected),
      runtime.selectPrivateTabID(selected.uuidString, windowID: windowID, contextID: contextID)
    {
      selectedTabID = selected
    }
    for id in store.selectedSplit?.tabIDs ?? [] {
      runtime.view(
        forPrivateTabID: id.uuidString, windowID: windowID,
        contextID: contextID)?.isHidden = false
    }
  }

  func navigateCurrentPage(to url: URL) -> Bool {
    guard let id = store?.session.selectedPage?.tab.id else { return false }
    return navigate(id, to: url)
  }

  func focusPage(_ id: UUID) {
    guard let store, !store.commandIsOpen, store.sheet == nil, store.pageFind == nil,
      store.session.selectedPage?.tab.id == id,
      let view = runtime.view(
        forPrivateTabID: id.uuidString, windowID: windowID, contextID: contextID),
      let window = view.window, window.isKeyWindow
    else { return }
    _ = runtime.focusPrivateTabID(id.uuidString, windowID: windowID, contextID: contextID)
    window.makeFirstResponder(view)
  }

  func navigate(_ id: UUID, to url: URL) -> Bool {
    guard liveTabs.contains(id), allow(url, for: id) else { return false }
    failure = nil
    return runtime.navigatePrivateTabID(
      id.uuidString, windowID: windowID,
      contextID: contextID, url: url.absoluteString)
  }

  func reload(_ id: UUID, mode: PageReloadMode = .normal) -> Bool {
    guard liveTabs.contains(id) else { return false }
    return runtime.reloadPrivateTabID(
      id.uuidString, windowID: windowID, contextID: contextID, mode: mode.engineMode)
  }

  func goBack(_ id: UUID) {
    guard liveTabs.contains(id) else { return }
    _ = runtime.goBackPrivateTabID(id.uuidString, windowID: windowID, contextID: contextID)
  }

  func goForward(_ id: UUID) {
    guard liveTabs.contains(id) else { return }
    _ = runtime.goForwardPrivateTabID(id.uuidString, windowID: windowID, contextID: contextID)
  }

  func close(_ id: UUID) {
    guard liveTabs.contains(id) else { return }
    runtime.closePrivateTabID(id.uuidString, windowID: windowID, contextID: contextID) { _ in }
  }

  func tabChanged(
    _ id: UUID, url: String, title: String, loading: Bool,
    back: Bool, forward: Bool
  ) {
    guard liveTabs.contains(id) || store?.session.page(forTabID: id) != nil else { return }
    if loading, store?.pageFind?.tabID == id { store?.dismissPageFind() }
    pages[id] = PageState(loading: loading, canGoBack: back, canGoForward: forward)
    if let parsed = URL(string: url) {
      if parsed.absoluteString != "about:blank" { failure = nil }
      store?.nativeTabChanged(id, url: parsed, title: title)
    }
  }

  func tabSelected(_ id: UUID) {
    guard let store, store.session.page(forTabID: id) != nil else { return }
    if pendingHTTPTabID != id { cancelHTTP() }
    selectedTabID = id
    _ = store.nativeTabActivated(id, profileID: store.session.selectedSpace.profileID)
  }

  func tabClosed(_ id: UUID) {
    guard liveTabs.remove(id) != nil else { return }
    pages[id] = nil
    if store?.pageFind?.tabID == id { store?.dismissPageFind() }
    store?.nativeTabClosed(id)
    if liveTabs.isEmpty { onEmpty?() }
  }

  func navigationFailed(_ message: String) { failure = message }

  private func allow(_ url: URL, for id: UUID) -> Bool {
    guard url.scheme?.lowercased() != "http" || approvedHTTP.remove(id) != nil else {
      pendingHTTP = url
      pendingHTTPTabID = id
      return false
    }
    return true
  }

  func confirmHTTP(useHTTPS: Bool) {
    guard let pendingHTTP, let id = pendingHTTPTabID,
      store?.session.selectedPage?.tab.id == id
    else {
      cancelHTTP()
      return
    }
    self.pendingHTTP = nil
    pendingHTTPTabID = nil
    var parts = URLComponents(url: pendingHTTP, resolvingAgainstBaseURL: false)
    if useHTTPS { parts?.scheme = "https" }
    guard let destination = parts?.url else { return }
    if liveTabs.contains(id) {
      if !useHTTPS { approvedHTTP.insert(id) }
      _ = navigate(id, to: destination)
    } else {
      do {
        try runtime.openPrivateTabID(
          id.uuidString, windowID: windowID,
          contextID: contextID, url: destination.absoluteString)
        liveTabs.insert(id)
        _ = runtime.selectPrivateTabID(
          id.uuidString, windowID: windowID,
          contextID: contextID)
        selectedTabID = id
      } catch { failure = error.localizedDescription }
    }
  }

  func cancelHTTP() {
    pendingHTTP = nil
    pendingHTTPTabID = nil
  }
}

struct PrivateBrowserPage: NSViewRepresentable {
  let session: PrivatePageSession
  let tabID: UUID
  var inSplit = false

  func makeNSView(context: Context) -> ChromiumPageContainerView {
    let view = ChromiumPageContainerView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    return view
  }

  func updateNSView(_ view: ChromiumPageContainerView, context: Context) {
    let native = session.runtime.view(
      forPrivateTabID: tabID.uuidString, windowID: session.windowID,
      contextID: session.contextID)
    _ = view.attach(native)
    if inSplit { native?.isHidden = false }
  }

  static func dismantleNSView(_ view: ChromiumPageContainerView, coordinator: ()) {
    view.attach(nil)
  }
}

// Verification fixtures exercise the same browser model used by the product window.
extension BrowserStore {
  var tabs: [PrivateBrowserTab] {
    session.selectedSpace.tabs.map(privateTab)
  }
  var selectedTabID: String { session.selectedPage?.tab.id.uuidString ?? "" }
  var selectedTab: PrivateBrowserTab? { session.selectedPage.map { privateTab($0.tab) } }
  private func privateTab(_ tab: BrowserTab) -> PrivateBrowserTab {
    let state = privatePage?.pages[tab.id]
    return PrivateBrowserTab(
      id: tab.id.uuidString, url: tab.url.absoluteString, title: tab.title,
      loading: state?.loading ?? false, canGoBack: state?.canGoBack ?? false,
      canGoForward: state?.canGoForward ?? false)
  }
  var windowID: String { privatePage?.windowID ?? "" }
  var contextID: String { privatePage?.contextID ?? "" }
  var showsStartPage: Bool { session.selectedPage?.tab.url.absoluteString == "about:blank" }
  var searchEngine: BrowserSearchEngine {
    preferences.searchEngine(for: session.selectedSpace.profileID)
  }

  func openTab() {
    let tab = BrowserTab(url: URL(string: "about:blank")!)
    _ = nativeTabOpened(
      tab, profileID: session.selectedSpace.profileID,
      openerID: nil, foreground: true)
  }
  func selectTab(_ id: String) {
    guard let id = UUID(uuidString: id) else { return }
    session.selectTab(id, in: session.selectedSpaceID)
    save()
  }
  func navigate(_ value: String) {
    guard let url = NavigationInput.destination(for: value, searchEngine: searchEngine) else {
      return
    }
    _ = privatePage?.navigateCurrentPage(to: url)
  }
  func confirmHTTP(useHTTPS: Bool) { privatePage?.confirmHTTP(useHTTPS: useHTTPS) }
  func submitCommand() {
    guard !commandQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    navigate(commandQuery)
    dismissCommand()
  }
  func goBack() {
    guard let id = session.selectedPage?.tab.id else { return }
    privatePage?.goBack(id)
  }
  func goForward() {
    guard let id = session.selectedPage?.tab.id else { return }
    privatePage?.goForward(id)
  }
  func reload() { _ = reloadCurrentPage() }
}
