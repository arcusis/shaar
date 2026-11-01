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
