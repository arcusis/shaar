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
    #expect(navigated?.1 == "private terms")
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
