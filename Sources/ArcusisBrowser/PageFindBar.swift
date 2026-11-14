// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct PageFindBar: View {
  static let closeShortcut = KeyboardShortcut.cancelAction

  let store: BrowserStore
  let state: PageFindState
  @FocusState private var queryIsFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(
        PanelsL10n.string("Find in page"),
        text: Binding(
          get: { isCurrent ? store.pageFind?.query ?? "" : "" },
          set: { updateQuery($0) })
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel(PanelsL10n.string("Find in page"))
      .focused($queryIsFocused)
      .onSubmit { move(forward: true) }
      .onExitCommand { close() }
      Text(state.status)
        .font(.caption.monospacedDigit())
        .foregroundStyle(state.matchCount == 0 && !state.searching ? .primary : .secondary)
        .lineLimit(1)
        .accessibilityLabel(state.status)
        .accessibilityAddTraits(.updatesFrequently)
      Button {
        move(forward: false)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(!state.canMove)
      .accessibilityLabel(PanelsL10n.string("Previous match"))
      .help(PanelsL10n.string("Previous match (Shift-Command-G)"))
      Button {
        move(forward: true)
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(!state.canMove)
      .accessibilityLabel(PanelsL10n.string("Next match"))
      .help(PanelsL10n.string("Next match (Command-G)"))
      Button(PanelsL10n.string("Done"), role: .cancel) { close() }
        .keyboardShortcut(Self.closeShortcut)
        .help(PanelsL10n.string("Close find (Escape)"))
    }
    .controlSize(.small)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(.bar)
    .task(id: state.focusRequest) { if isCurrent { queryIsFocused = true } }
  }

  private var isCurrent: Bool { store.pageFind?.id == state.id && state.matches(store.session) }

  func updateQuery(_ query: String) {
    guard isCurrent else { return }
    store.updatePageFindQuery(query)
  }

  func move(forward: Bool) {
    guard isCurrent else { return }
    store.movePageFind(forward: forward)
  }

  func close() {
    guard isCurrent else { return }
    store.dismissPageFind()
    if state.matches(store.session), store.sheet == nil, !store.commandIsOpen {
      if let privatePage = store.privatePage {
        privatePage.focusPage(state.tabID)
      } else {
        store.engine?.runtime.focusTabID(state.tabID.uuidString)
      }
    }
  }
}
