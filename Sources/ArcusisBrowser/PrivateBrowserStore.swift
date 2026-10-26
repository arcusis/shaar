import Foundation
import Observation

struct PrivateBrowserTab: Identifiable, Equatable {
  let id: String
  var url: String
  var title: String
  var loading: Bool
  var canGoBack: Bool
  var canGoForward: Bool
}

@MainActor @Observable
final class PrivateBrowserStore {
  let contextID: String
  let windowID: String
  private(set) var tabs: [PrivateBrowserTab]
  private(set) var selectedTabID: String
  var address: String
  var commandIsOpen = false
  var commandQuery = ""
  var pageIsFocused = false
  @ObservationIgnored var onOpenTab: (() -> Void)?
  @ObservationIgnored var onNavigate: ((String, String) -> Void)?
  @ObservationIgnored var onCloseTab: ((String) -> Void)?
  @ObservationIgnored var onSelectTab: ((String) -> Void)?
  @ObservationIgnored var onReload: ((String) -> Void)?
  @ObservationIgnored var onBack: ((String) -> Void)?
  @ObservationIgnored var onForward: ((String) -> Void)?

  init(contextID: String, windowID: String, tabID: String, url: String) {
    self.contextID = contextID
    self.windowID = windowID
    selectedTabID = tabID
    address = url
    tabs = [
      PrivateBrowserTab(
        id: tabID, url: url, title: url, loading: true, canGoBack: false, canGoForward: false)
    ]
  }

  var selectedTab: PrivateBrowserTab? { tabs.first { $0.id == selectedTabID } }

  func openTab() { onOpenTab?() }
  func navigate(_ value: String) { onNavigate?(selectedTabID, value) }
  func closeTab(_ tabID: String) { onCloseTab?(tabID) }
  func selectTab(_ tabID: String) { onSelectTab?(tabID) }
  func reload() { onReload?(selectedTabID) }
  func goBack() { onBack?(selectedTabID) }
  func goForward() { onForward?(selectedTabID) }

  func receive(_ tab: PrivateBrowserTab) {
    if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
      tabs[index] = tab
    } else {
      tabs.append(tab)
    }
    if tab.id == selectedTabID { address = tab.url }
  }

  func select(_ tabID: String) {
    guard tabs.contains(where: { $0.id == tabID }) else { return }
    selectedTabID = tabID
    address = tabs.first(where: { $0.id == tabID })?.url ?? ""
  }

  func remove(_ tabID: String) {
    tabs.removeAll { $0.id == tabID }
    if selectedTabID == tabID, let next = tabs.last {
      select(next.id)
    }
  }

  func showCommand() {
    commandQuery = ""
    pageIsFocused = false
    commandIsOpen = true
  }

  func dismissCommand() {
    commandIsOpen = false
    pageIsFocused = true
  }

  func submitCommand() {
    let value = commandQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    commandIsOpen = false
    pageIsFocused = true
    navigate(value)
  }

  func clear() {
    onOpenTab = nil
    onNavigate = nil
    onCloseTab = nil
    onSelectTab = nil
    onReload = nil
    onBack = nil
    onForward = nil
    tabs.removeAll()
    address = ""
    commandQuery = ""
    commandIsOpen = false
    pageIsFocused = false
  }
}
