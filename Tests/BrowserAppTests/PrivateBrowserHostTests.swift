// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivateBrowserHostTests {
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
