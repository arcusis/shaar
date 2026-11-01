// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct PageNavigationButtons: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?

  var body: some View {
    let id = store.session.selectedPage?.tab.id
    let state = id.flatMap { engine?.pages[$0] }

    HStack(spacing: 4) {
      navigationButton("chevron.backward", label: ShellL10n.string("Back")) {
        if let id { engine?.runtime.goBack(inTabID: id.uuidString) }
      }
      .disabled(state?.canGoBack != true)

      navigationButton("chevron.forward", label: ShellL10n.string("Forward")) {
        if let id { engine?.runtime.goForward(inTabID: id.uuidString) }
      }
      .disabled(state?.canGoForward != true)

      navigationButton("arrow.clockwise", label: ShellL10n.string("Reload (Command-R)")) {
        store.reloadCurrentPage()
      }
      .disabled(!store.canReloadCurrentPage)
    }
  }

  private func navigationButton(
    _ symbol: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .help(label)
    .accessibilityLabel(label)
  }
}
