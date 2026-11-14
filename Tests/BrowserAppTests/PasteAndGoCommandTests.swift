// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Testing

@testable import ArcusisBrowser

@MainActor
private final class MemoryPasteboard: PasteAndGoPasteboard {
  var value: String?

  func string(forType type: NSPasteboard.PasteboardType) -> String? { value }
  func setString(_ string: String) { value = string }
}

@Test @MainActor func pasteAndGoRoutesURLOrSearchTextAndRejectsUnsupportedSchemes() throws {
  let pasteboard = MemoryPasteboard()
  var routed: URL?
  func route(_ text: String) -> Bool {
    pasteboard.setString(text)
    return PasteAndGoCommand.route(in: pasteboard, searchEngine: .google) { url in
      routed = url
      return true
    }
  }

  #expect(route("https://example.com/path"))
  #expect(routed?.absoluteString == "https://example.com/path")
  #expect(route("two words"))
  #expect(routed?.host() == "www.google.com")
  #expect(!route("javascript:alert(1)"))
  #expect(routed?.host() == "www.google.com")
}

@Test @MainActor func pasteAndGoOpensAnEmptySelectedSpaceWithoutNativeNavigation() throws {
  let pasteboard = MemoryPasteboard()
  let store = BrowserStore()
  let destination = URL(string: "https://empty-tab.example/path")!
  #expect(store.session.selectedPage == nil)
  pasteboard.setString(destination.absoluteString)
  var nativeNavigationRequested = false

  #expect(
    PasteAndGoCommand.route(in: pasteboard, store: store, searchEngine: .google) { _ in
      nativeNavigationRequested = true
      return true
    })

  #expect(!nativeNavigationRequested)
  #expect(store.session.selectedPage?.tab.url == destination)
}

@Test @MainActor func pasteAndGoOpensAnEmptyPrivateSpace() throws {
  let pasteboard = MemoryPasteboard()
  let destination = URL(string: "https://private-empty-tab.example/path")!
  let session = try BrowserSession.privateWindow(sourceProfileID: UUID(), firstTabID: UUID())
  let store = BrowserStore(privateSession: session)
  store.session.closeTab(session.selectedSpace.tabs[0].id)

  #expect(store.session.selectedPage == nil)
  #expect(
    !PrivateBrowserHost.windowCanPerform(
      .pasteAndGo, store: store, pasteboard: pasteboard, searchEngine: .google))
  pasteboard.setString(destination.absoluteString)
  #expect(
    PrivateBrowserHost.windowCanPerform(
      .pasteAndGo, store: store, pasteboard: pasteboard, searchEngine: .google))
  #expect(
    PasteAndGoCommand.route(in: pasteboard, store: store, searchEngine: .google) { _ in false })
  #expect(store.session.selectedPage?.tab.url == destination)
}

@Test @MainActor func pasteAndGoNavigatesTheSelectedPrivatePage() throws {
  let pasteboard = MemoryPasteboard()
  let destination = URL(string: "https://private-selected-page.example/path")!
  pasteboard.setString(destination.absoluteString)
  let session = try BrowserSession.privateWindow(sourceProfileID: UUID(), firstTabID: UUID())
  let store = BrowserStore(privateSession: session)
  let currentURL = URL(string: "https://private-current-page.example/")!
  store.perform(.open(currentURL))
  var navigated: URL?

  #expect(store.session.selectedPage != nil)
  #expect(
    PasteAndGoCommand.route(in: pasteboard, store: store, searchEngine: .google) { url in
      navigated = url
      return true
    })
  #expect(navigated == destination)
  #expect(store.session.selectedPage?.tab.url == currentURL)
}
