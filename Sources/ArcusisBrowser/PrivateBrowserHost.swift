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
    let store: PrivateBrowserStore
    let window: NSWindow
    let hosting: NSHostingView<PrivateBrowserWindow?>
    let titlebarDragView: NSView
  }

  private let runtime: ARCChromiumRuntime
  private let keyWindow: () -> NSWindow?
  private let sourceProfileID: () -> String?
  private let presentsWindows: Bool
  private var owners: [String: Owner] = [:]
  private var contextsBySource: [String: String] = [:]
  private var windowsByContext: [String: Set<String>] = [:]
  private var pendingWindowRequests: [String: [(String, String)]] = [:]

  init(
    runtime: ARCChromiumRuntime, presentsWindows: Bool = true,
    keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
    sourceProfileID: @escaping () -> String?
  ) {
    self.runtime = runtime
    self.presentsWindows = presentsWindows
    self.keyWindow = keyWindow
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
    runtime.onPrivateTabChanged = {
      [weak self] context, window, tab, url, title, loading, back, forward in
      self?.tabChanged(
        context: context, window: window, tab: tab, url: url, title: title,
        loading: loading, back: back, forward: forward)
    }
    runtime.onPrivateTabSelected = { [weak self] context, window, tab in
      self?.tabSelected(context: context, window: window, tab: tab)
    }
    runtime.onPrivateTabClosed = { [weak self] context, window, tab in
      self?.tabClosed(context: context, window: window, tab: tab)
    }
    runtime.onPrivateWindowClosed = { [weak self] context, window in
      self?.windowClosed(context: context, window: window)
    }
  }

  func detach() {
    runtime.onPrivateTabChanged = nil
    runtime.onPrivateTabSelected = nil
    runtime.onPrivateTabClosed = nil
    runtime.onPrivateWindowClosed = nil
    for owner in owners.values {
      retire(owner)
    }
  }

  /// Retire SwiftUI bindings before AppKit or its field editor can keep them alive.
  static func retireHostingContent<Content: View>(_ hosting: NSHostingView<Content?>) {
    hosting.rootView = nil
    hosting.layoutSubtreeIfNeeded()
    hosting.removeFromSuperview()
  }

  private func retire(_ owner: Owner) {
    owner.window.endEditing(for: nil)
    _ = owner.window.makeFirstResponder(nil)
    Self.retireHostingContent(owner.hosting)
    owner.titlebarDragView.removeFromSuperview()
    owner.store.clear()
  }

  func openWindow() throws {
    guard !runtime.isQuitting, let source = sourceProfileID() else {
      throw WorkspaceError.invalidState
    }
    let contextID = contextsBySource[source] ?? UUID().uuidString.uppercased()
    let windowID = UUID().uuidString.uppercased()
    let tabID = UUID().uuidString.uppercased()
    if let context = contextsBySource[source] {
      if pendingWindowRequests[context] != nil {
        pendingWindowRequests[context, default: []].append((windowID, tabID))
      } else {
        createWindow(
          context: context, source: source, window: windowID, tab: tabID, url: "about:blank")
      }
    } else {
      contextsBySource[source] = contextID
      windowsByContext[contextID] = []
      pendingWindowRequests[contextID] = [(windowID, tabID)]
      runtime.createPrivateContextID(contextID, sourceProfileID: source) {
        [weak self] success, error in
        guard let self else { return }
        guard success, !self.runtime.isQuitting,
          self.sourceProfileID() == source,
          self.contextsBySource[source] == contextID,
          self.windowsByContext[contextID] != nil
        else {
          self.pendingWindowRequests.removeValue(forKey: contextID)
          if self.contextsBySource[source] == contextID {
            self.contextsBySource.removeValue(forKey: source)
          }
          if self.windowsByContext[contextID]?.isEmpty == true {
            self.windowsByContext.removeValue(forKey: contextID)
          }
          if success, self.windowsByContext[contextID] == nil {
            _ = self.runtime.releasePrivateContextID(contextID)
          }
          _ = error
          return
        }
        let requests = self.pendingWindowRequests.removeValue(forKey: contextID) ?? []
        for (windowID, tabID) in requests {
          self.createWindow(
            context: contextID, source: source, window: windowID, tab: tabID,
            url: "about:blank")
        }
      }
    }
  }

  func canPerform(_ command: BrowserMenuCommand) -> Bool {
    guard activeOwner != nil else { return false }
    guard !runtime.isQuitting else { return false }
    return Self.supportsPrivateCommand(command)
  }

  static func supportsPrivateCommand(_ command: BrowserMenuCommand) -> Bool {
    [.newTab, .search, .closeTab, .closeWindow, .reload].contains(command)
  }

  func perform(_ command: BrowserMenuCommand) {
    guard let owner = activeOwner, canPerform(command) else { return }
    switch command {
    case .newTab:
      owner.store.openTab()
      owner.store.showCommand()
    case .search: owner.store.showCommand()
    case .closeTab:
      if owner.store.tabs.count > 1, let tab = owner.store.selectedTab {
        owner.store.closeTab(tab.id)
      } else {
        closeWindow(context: owner.contextID, window: owner.windowID)
      }
    case .closeWindow: closeWindow(context: owner.contextID, window: owner.windowID)
    case .reload: owner.store.reload()
    default: break
    }
  }

  private func createWindow(
    context: String, source: String, window: String, tab: String, url: String
  ) {
    guard !runtime.isQuitting else { return }
    do { try runtime.createPrivateWindowID(window, contextID: context, tabID: tab, url: url) } catch
    {
      releaseEmptyContext(context, source: source)
      return
    }
    guard let nativeWindow = runtime.window(forPrivateWindowID: window, contextID: context) else {
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
    let store = PrivateBrowserStore(contextID: context, windowID: window, tabID: tab, url: url)
    let hosting = NSHostingView<PrivateBrowserWindow?>(
      rootView: PrivateBrowserWindow(store: store, runtime: runtime))
    hosting.frame = nativeWindow.contentView?.bounds ?? .zero
    hosting.autoresizingMask = [.width, .height]
    guard let container = runtime.hostView(forPrivateWindowID: window, contextID: context) else {
      runtime.closePrivateWindowID(window, contextID: context) { [weak self] closed in
        if closed { self?.releaseEmptyContext(context, source: source) }
      }
      return
    }
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    let titlebarHost = nativeWindow.contentView?.superview ?? container
    let titlebarDragView = WindowDragRegion.makeTitlebarDragView(
      window: nativeWindow, contentView: titlebarHost,
      isRightToLeft: BrowserLanguage.currentLaunchLanguage.isRightToLeft)
    titlebarHost.addSubview(titlebarDragView, positioned: .above, relativeTo: nil)
    let owner = Owner(
      contextID: context, sourceProfileID: source, windowID: window, store: store,
      window: nativeWindow, hosting: hosting, titlebarDragView: titlebarDragView)
    owners[window] = owner
    windowsByContext[context, default: []].insert(window)
    store.onOpenTab = { [weak self] in self?.openTab(context: context, window: window) }
    store.onNavigate = { [weak self] id, value in
      self?.navigate(id, value, context: context, window: window)
    }
    store.onCloseTab = { [weak self] id in
      self?.closeTab(id, context: context, window: window)
    }
    store.onSelectTab = { [weak self] id in
      guard let self,
        self.runtime.selectPrivateTabID(id, windowID: window, contextID: context),
        self.owners[window]?.contextID == context
      else { return }
      self.owners[window]?.store.select(id)
    }
    store.onReload = { [weak self] id in
      guard let self, self.owners[window]?.contextID == context else { return }
      _ = self.runtime.reloadPrivateTabID(id, windowID: window, contextID: context)
    }
    store.onBack = { [weak self] id in
      guard let self, self.owners[window]?.contextID == context else { return }
      _ = self.runtime.goBackPrivateTabID(id, windowID: window, contextID: context)
    }
    store.onForward = { [weak self] id in
      guard let self, self.owners[window]?.contextID == context else { return }
      _ = self.runtime.goForwardPrivateTabID(id, windowID: window, contextID: context)
    }
    if presentsWindows { nativeWindow.makeKeyAndOrderFront(nil) }
  }

  private func openTab(context: String, window: String) {
    guard let owner = owners[window], owner.contextID == context else { return }
    let id = UUID().uuidString.uppercased()
    do {
      try runtime.openPrivateTabID(
        id, windowID: owner.windowID, contextID: owner.contextID, url: "about:blank")
    } catch { return }
    guard runtime.selectPrivateTabID(id, windowID: owner.windowID, contextID: owner.contextID)
    else {
      runtime.closePrivateTabID(id, windowID: owner.windowID, contextID: owner.contextID) { _ in }
      return
    }
    owner.store.select(id)
  }

  private func navigate(_ id: String, _ value: String, context: String, window: String) {
    guard let owner = owners[window], owner.contextID == context else { return }
    let address: String
    if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "about:blank" {
      address = "about:blank"
    } else if let destination = NavigationInput.destination(for: value) {
      address = destination.absoluteString
    } else {
      return
    }
    guard
      runtime.navigatePrivateTabID(
        id, windowID: window, contextID: context, url: address)
    else { return }
    owner.store.address = address
  }

  private func closeTab(_ id: String, context: String, window: String) {
    guard owners[window]?.contextID == context else { return }
    runtime.closePrivateTabID(id, windowID: window, contextID: context) {
      [weak self] closed in
      guard let self, closed, let owner = self.owners[window], owner.contextID == context else {
        return
      }
      owner.store.remove(id)
      if owner.store.tabs.isEmpty { self.closeWindow(context: context, window: window) }
    }
  }

  private func closeWindow(context: String, window: String) {
    guard owners[window]?.contextID == context else { return }
    runtime.closePrivateWindowID(window, contextID: context) { _ in }
  }

  private func releaseEmptyContext(_ context: String, source: String) {
    guard windowsByContext[context]?.isEmpty == true,
      contextsBySource[source] == context
    else { return }
    windowsByContext.removeValue(forKey: context)
    contextsBySource.removeValue(forKey: source)
    _ = runtime.releasePrivateContextID(context)
  }

  private func tabChanged(
    context: String, window: String, tab: String, url: String, title: String,
    loading: Bool, back: Bool, forward: Bool
  ) {
    guard let owner = owners[window], owner.contextID == context else { return }
    owner.store.receive(
      PrivateBrowserTab(
        id: tab, url: url, title: title, loading: loading,
        canGoBack: back, canGoForward: forward))
  }

  private func tabSelected(context: String, window: String, tab: String) {
    guard let owner = owners[window], owner.contextID == context else { return }
    owner.store.select(tab)
  }

  private func tabClosed(context: String, window: String, tab: String) {
    guard let owner = owners[window], owner.contextID == context else { return }
    owner.store.remove(tab)
  }

  private func windowClosed(context: String, window: String) {
    guard let owner = owners[window], owner.contextID == context else { return }
    owners.removeValue(forKey: window)
    retire(owner)
    windowsByContext[context]?.remove(window)
    if windowsByContext[context]?.isEmpty == true {
      windowsByContext.removeValue(forKey: context)
      contextsBySource.removeValue(forKey: owner.sourceProfileID)
      _ = runtime.releasePrivateContextID(context)
    }
  }
}
