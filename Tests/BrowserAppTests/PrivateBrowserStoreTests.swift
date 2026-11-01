// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivateBrowserStoreTests {
  @Test func tabsAndSelectionStayInsideTransientPrivateStore() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "about:blank")
    #expect(store.tabs.map(\.id) == ["first"])
    #expect(store.selectedTabID == "first")
    store.receive(
      PrivateBrowserTab(
        id: "second", url: "http://127.0.0.1:43123/private", title: "Private", loading: false,
        canGoBack: true, canGoForward: false))
    store.select("second")
    #expect(store.selectedTab?.title == "Private")
    #expect(store.address == "http://127.0.0.1:43123/private")
    store.remove("second")
    #expect(store.selectedTabID == "first")
    #expect(store.tabs.map(\.id) == ["first"])
  }

  @Test func commandUsesPrivateAddressCallbackWithoutNormalSearchResults() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "about:blank")
    var navigated: (String, String)?
    store.onNavigate = { navigated = ($0, $1) }
    store.showCommand()
    store.commandQuery = "private terms"
    store.submitCommand()
    #expect(store.commandIsOpen == false)
    #expect(navigated?.0 == "first")
    #expect(navigated?.1 == "https://www.google.com/search?q=private%20terms")
  }
}

extension PrivateBrowserStoreTests {
  @Test func pageControlsTargetTheSelectedPrivateTab() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "about:blank")
    var calls: [String] = []
    store.onOpenTab = { calls.append("open") }
    store.onCloseTab = { calls.append("close \($0)") }
    store.onSelectTab = { calls.append("select \($0)") }
    store.onReload = { calls.append("reload \($0)") }
    store.onBack = { calls.append("back \($0)") }
    store.onForward = { calls.append("forward \($0)") }
    store.openTab()
    store.selectTab("second")
    store.closeTab("second")
    store.reload()
    store.goBack()
    store.goForward()
    #expect(
      calls == [
        "open", "select second", "close second", "reload first", "back first", "forward first",
      ])
  }

  @Test func engineUpdatesReplaceTabsAndKeepTheAddressInSync() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "about:blank")
    store.receive(
      PrivateBrowserTab(
        id: "first", url: "https://example.com/", title: "Example", loading: false,
        canGoBack: true, canGoForward: false))
    #expect(store.tabs.count == 1)
    #expect(store.address == "https://example.com/")
    store.select("missing")
    #expect(store.selectedTabID == "first")
    store.receive(
      PrivateBrowserTab(
        id: "second", url: "https://other.example/", title: "Other", loading: true,
        canGoBack: false, canGoForward: false))
    #expect(store.address == "https://example.com/")
  }

  @Test func commandDismissalAndBlankSubmissionReturnFocusWithoutNavigating() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "about:blank")
    var navigations = 0
    store.onNavigate = { _, _ in navigations += 1 }
    store.showCommand()
    store.commandQuery = "   "
    store.submitCommand()
    #expect(store.commandIsOpen && navigations == 0)
    store.dismissCommand()
    #expect(!store.commandIsOpen && store.pageIsFocused)
  }

  @Test func clearingDetachesEngineCallbacksAndForgetsPrivateState() {
    let store = PrivateBrowserStore(
      contextID: "private-context", windowID: "private-window", tabID: "first",
      url: "https://example.com/")
    var navigations = 0
    store.onNavigate = { _, _ in navigations += 1 }
    store.showCommand()
    store.commandQuery = "secret"
    store.clear()
    store.navigate("https://example.com/after")
    #expect(navigations == 0)
    #expect(store.tabs.isEmpty && store.address.isEmpty && store.commandQuery.isEmpty)
    #expect(!store.commandIsOpen && !store.pageIsFocused)
  }
}

extension PrivateBrowserStoreTests {
  @Test func privateStartSearchUsesSelectedProfileEngine() {
    let store = PrivateBrowserStore(
      contextID: "context", windowID: "window", tabID: "tab", url: "about:blank",
      searchEngine: .duckDuckGo)
    var navigated: String?
    store.onNavigate = { _, value in navigated = value }
    #expect(store.showsStartPage && store.address.isEmpty)
    store.navigate("private query")
    #expect(navigated == "https://duckduckgo.com/?q=private%20query")
  }

  @Test func plainHTTPRequiresExplicitChoiceAndHTTPSIsPreferred() {
    let store = PrivateBrowserStore(
      contextID: "context", windowID: "window", tabID: "tab", url: "about:blank")
    var navigations: [String] = []
    store.onNavigate = { _, value in navigations.append(value) }
    store.navigate("http://example.com/path?q=1")
    #expect(navigations.isEmpty && store.pendingHTTP?.host() == "example.com")
    store.confirmHTTP(useHTTPS: true)
    #expect(navigations == ["https://example.com/path?q=1"])
    store.navigate("http://example.com/path?q=1")
    store.confirmHTTP(useHTTPS: false)
    #expect(navigations.last == "http://example.com/path?q=1")
    store.navigate("http://example.com/cancel")
    store.cancelHTTP()
    store.confirmHTTP(useHTTPS: false)
    #expect(navigations.count == 2)
    store.navigate("http://example.com/stale")
    store.navigate("about:blank")
    store.confirmHTTP(useHTTPS: false)
    #expect(
      navigations == ["https://example.com/path?q=1", "http://example.com/path?q=1", "about:blank"])
  }

  @Test func pendingHTTPCannotFollowTabSelectionOrWindowClose() {
    let store = PrivateBrowserStore(
      contextID: "context", windowID: "window", tabID: "first", url: "about:blank")
    var navigations = 0
    store.onNavigate = { _, _ in navigations += 1 }
    store.receive(
      PrivateBrowserTab(
        id: "second", url: "about:blank", title: "", loading: false, canGoBack: false,
        canGoForward: false))
    store.navigate("http://example.com/")
    store.select("second")
    store.confirmHTTP(useHTTPS: false)
    #expect(navigations == 0 && store.pendingHTTP == nil)
    store.navigate("http://example.com/")
    store.clear()
    store.confirmHTTP(useHTTPS: false)
    #expect(navigations == 0 && store.pendingHTTP == nil)
  }
}
