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
