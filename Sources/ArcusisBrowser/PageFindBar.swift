// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct PageFindBar: View {
  let store: BrowserStore
  let state: PageFindState
  @FocusState private var queryIsFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(
        "Find in page",
        text: Binding(
          get: { isCurrent ? store.pageFind?.query ?? "" : "" },
          set: { if isCurrent { store.updatePageFindQuery($0) } })
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("Find in page")
      .focused($queryIsFocused)
      .onSubmit { if isCurrent { store.movePageFind(forward: true) } }
      .onExitCommand { close() }
      Text(state.status)
        .font(.caption.monospacedDigit())
        .foregroundStyle(state.matchCount == 0 && !state.searching ? .primary : .secondary)
        .lineLimit(1)
        .accessibilityLabel(state.status)
      Button {
        if isCurrent { store.movePageFind(forward: false) }
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(!state.canMove)
      .accessibilityLabel("Previous match")
      .help("Previous match (Shift-Command-G)")
      Button {
        if isCurrent { store.movePageFind(forward: true) }
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(!state.canMove)
      .accessibilityLabel("Next match")
      .help("Next match (Command-G)")
      Button("Done") { close() }
        .help("Close find (Escape)")
    }
    .controlSize(.small)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(.bar)
    .task(id: state.focusRequest) { if isCurrent { queryIsFocused = true } }
  }

  private var isCurrent: Bool { store.pageFind?.id == state.id && state.matches(store.session) }

  private func close() {
    guard isCurrent else { return }
    store.dismissPageFind()
    if state.matches(store.session), store.sheet == nil, !store.commandIsOpen {
      store.engine?.runtime.focusTabID(state.tabID.uuidString)
    }
  }
}
