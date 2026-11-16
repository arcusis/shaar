// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct NavigationLoadingPresentation: Equatable {
  let symbol: String
  let labelKey: String

  static func forLoadingState(_ isLoading: Bool) -> Self {
    Self(
      symbol: isLoading ? "xmark" : "arrow.clockwise",
      labelKey: isLoading ? "Stop Loading" : "Reload (Command-R)")
  }
}

struct PageNavigationButtons: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?
  var tabID: UUID? = nil

  var body: some View {
    let id = tabID ?? store.session.selectedPage?.tab.id
    let state = id.flatMap { engine?.pages[$0] ?? store.privatePage?.pages[$0] }
    let loadingPresentation = NavigationLoadingPresentation.forLoadingState(state?.loading == true)

    HStack(spacing: tabID == nil ? 4 : 0) {
      navigationButton("chevron.backward", label: ShellL10n.string("Back")) {
        goBack()
      }
      .disabled(state?.canGoBack != true)
      .browserChromeControl("browser.chrome.back")

      navigationButton("chevron.forward", label: ShellL10n.string("Forward")) {
        goForward()
      }
      .disabled(state?.canGoForward != true)
      .browserChromeControl("browser.chrome.forward")

      navigationButton(
        loadingPresentation.symbol,
        label: ShellL10n.string(loadingPresentation.labelKey)
      ) {
        if let tabID { store.focusSplitTab(tabID) }
        if state?.loading == true { store.stopCurrentPage() } else { store.reloadCurrentPage() }
      }
      .disabled(
        state?.loading == true
          ? false : (tabID.map { !store.canReloadPage($0) } ?? !store.canReloadCurrentPage)
      )
      .browserChromeControl(
        state?.loading == true ? "browser.chrome.stop" : "browser.chrome.reload")
    }
  }

  func goBack() {
    guard let id = tabID ?? store.session.selectedPage?.tab.id else { return }
    if tabID != nil { store.focusSplitTab(id) }
    if let privatePage = store.privatePage {
      privatePage.goBack(id)
    } else {
      engine?.runtime.goBack(inTabID: id.uuidString)
    }
  }

  func goForward() {
    guard let id = tabID ?? store.session.selectedPage?.tab.id else { return }
    if tabID != nil { store.focusSplitTab(id) }
    if let privatePage = store.privatePage {
      privatePage.goForward(id)
    } else {
      engine?.runtime.goForward(inTabID: id.uuidString)
    }
  }

  private func navigationButton(
    _ symbol: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .frame(width: tabID == nil ? 28 : 22, height: tabID == nil ? 28 : 22)
        .contentShape(Rectangle())
    }
    .help(label)
    .accessibilityLabel(label)
  }
}
