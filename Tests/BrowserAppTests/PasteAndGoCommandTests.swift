// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Testing

@testable import ArcusisBrowser

@Test @MainActor func pasteAndGoRoutesURLOrSearchTextAndRejectsUnsupportedSchemes() throws {
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteAndGoCommandTests"))
  var routed: URL?
  func route(_ text: String) -> Bool {
    pasteboard.clearContents()
    #expect(pasteboard.setString(text, forType: .string))
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
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteAndGoEmptySpaceTests"))
  let store = BrowserStore()
  let destination = URL(string: "https://empty-tab.example/path")!
  #expect(store.session.selectedPage == nil)
  #expect(pasteboard.setString(destination.absoluteString, forType: .string))
  var nativeNavigationRequested = false

  #expect(
    PasteAndGoCommand.route(in: pasteboard, store: store, searchEngine: .google) { _ in
      nativeNavigationRequested = true
      return true
    })

  #expect(!nativeNavigationRequested)
  #expect(store.session.selectedPage?.tab.url == destination)
}
