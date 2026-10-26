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
