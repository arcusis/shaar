// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivateBrowserHostTests {
  @Test func retiringHostedContentReleasesItsModelWhileHostingViewRemainsAlive() async throws {
    weak var releasedStore: PrivateBrowserStore?
    let hosting = autoreleasepool {
      let store = PrivateBrowserStore(
        contextID: "context", windowID: "window", tabID: "tab", url: "about:blank")
      releasedStore = store
      return NSHostingView<StoreBindingView?>(rootView: StoreBindingView(store: store))
    }
    hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
    hosting.layoutSubtreeIfNeeded()
    #expect(releasedStore != nil)
    PrivateBrowserHost.retireHostingContent(hosting)
    #expect(hosting.rootView == nil)
    for _ in 0..<100 {
      if releasedStore == nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(releasedStore == nil)
  }

  @Test func cachedHTTPWarningDoesNotRetainPrivateStoreAfterRetirement() {
    weak var releasedStore: PrivateBrowserStore?
    let (warning, cachedBinding) = autoreleasepool {
      let store = PrivateBrowserStore(
        contextID: "context", windowID: "window", tabID: "tab", url: "about:blank")
      store.navigate("http://example.com/private")
      releasedStore = store
      let warning = PrivateHTTPWarning(store: store)
      return (warning, warning.isPresented)
    }
    #expect(releasedStore == nil)
    #expect(!cachedBinding.wrappedValue)
    cachedBinding.wrappedValue = false
    warning.confirm(useHTTPS: false)
    warning.cancel()
    #expect(releasedStore == nil)
  }

  @Test func httpWarningPreservesConsentWhilePrivateStoreIsOwned() {
    let store = PrivateBrowserStore(
      contextID: "context", windowID: "window", tabID: "tab", url: "about:blank")
    let warning = PrivateHTTPWarning(store: store)
    var navigations: [String] = []
    store.onNavigate = { _, value in navigations.append(value) }
    store.navigate("http://example.com/private")
    #expect(warning.isPresented.wrappedValue)
    warning.confirm(useHTTPS: true)
    #expect(navigations == ["https://example.com/private"])
    #expect(!warning.isPresented.wrappedValue)
    store.navigate("http://example.com/cancel")
    warning.isPresented.wrappedValue = false
    #expect(store.pendingHTTP == nil && navigations.count == 1)
    store.navigate("http://example.com/private")
    warning.confirm(useHTTPS: false)
    #expect(navigations.last == "http://example.com/private")
  }

  @Test func privateOwnerCommandSurfaceExcludesNormalBrowserServices() {
    for command in [.newTab, .search, .closeTab, .closeWindow, .reload] as [BrowserMenuCommand] {
      #expect(PrivateBrowserHost.supportsPrivateCommand(command))
    }
    for command in [
      .newSpace, .editSpace, .addFavorite, .reopenClosed, .recentlyClosed,
      .bookmarkPage, .bookmarks, .history, .downloads, .extensions, .find,
    ] as [BrowserMenuCommand] {
      #expect(!PrivateBrowserHost.supportsPrivateCommand(command))
    }
  }
}

private struct StoreBindingView: View {
  @Bindable var store: PrivateBrowserStore

  var body: some View {
    TextField("Private address", text: $store.address)
  }
}
