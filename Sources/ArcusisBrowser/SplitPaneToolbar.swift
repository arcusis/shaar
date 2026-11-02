// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

/// Back, forward, reload and the address for one pane of a split.
struct SplitPaneToolbar: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?
  let tabID: UUID

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.layoutDirection) private var layoutDirection

  private var tab: BrowserTab? {
    store.session.selectedSpace.tabs.first { $0.id == tabID }
  }

  private var isFocused: Bool {
    store.session.selectedSpace.selectedTabID == tabID
  }

  var body: some View {
    let state = engine?.pages[tabID]
    HStack(spacing: 2) {
      toolbarButton("chevron.backward", label: ShellL10n.string("Back")) {
        engine?.runtime.goBack(inTabID: tabID.uuidString)
      }
      .disabled(state?.canGoBack != true)
      toolbarButton("chevron.forward", label: ShellL10n.string("Forward")) {
        engine?.runtime.goForward(inTabID: tabID.uuidString)
      }
      .disabled(state?.canGoForward != true)
      toolbarButton("arrow.clockwise", label: ShellL10n.string("Reload")) {
        focus()
        store.reloadCurrentPage()
      }
      address
      toolbarButton("plus", label: ShellL10n.string("New Tab in Split")) {
        store.openSplitPane(beside: tabID, edge: physicalRightEdge)
      }
      .disabled(store.selectedSplitIsFull)
      paneMenu
    }
    .padding(.horizontal, 4)
    .frame(height: 30)
    .background(
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
        .opacity(isFocused ? 1 : 0.6)
    )
    .buttonStyle(.plain)
  }

  private var address: some View {
    Button {
      focus()
      store.showCommand()
      store.commandQuery = tab?.url.absoluteString ?? ""
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "link").font(.system(size: 10))
        Text(tab?.url.host() ?? tab?.title ?? "")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.system(size: 12))
      .foregroundStyle(isFocused ? .primary : .secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 24)
      .contentShape(Rectangle())
    }
    .help(tab?.url.absoluteString ?? "")
    .accessibilityLabel(ShellL10n.format("Address %@", arguments: [.string(tab?.url.host() ?? "")]))
    .draggable(
      store.beginTabDrag(tabID, spaceID: store.session.selectedSpaceID, fromSplitPane: true)
    ) {
      Label(tab?.title ?? "", systemImage: "link")
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.regularMaterial, in: Capsule())
    }
  }

  private var paneMenu: some View {
    Menu {
      Button(ShellL10n.string("New Tab to the Right")) {
        store.openSplitPane(beside: tabID, edge: physicalRightEdge)
      }
      .disabled(store.selectedSplitIsFull)
      Button(ShellL10n.string("New Tab Below")) {
        store.openSplitPane(beside: tabID, edge: .bottom)
      }
      .disabled(store.selectedSplitIsFull)
      Divider()
      Button(ShellL10n.string("Separate from Split")) { store.unsplitTab(tabID) }
      Button(ShellL10n.string("Close Tab")) { store.closeTab(tabID) }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(ShellL10n.string("Pane options"))
    .accessibilityLabel(ShellL10n.string("Pane options"))
  }

  private var physicalRightEdge: SplitEdge {
    .forPhysicalRight(isRightToLeft: layoutDirection == .rightToLeft)
  }

  private func focus() {
    if !isFocused { store.focusSplitTab(tabID) }
  }

  private func toolbarButton(
    _ symbol: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .help(label)
    .accessibilityLabel(label)
  }
}

/// Arc's split controls: pick an arrangement for the panes of the selected split.
struct SplitLayoutControls: View {
  @Bindable var store: BrowserStore
  let split: BrowserSplit
  @Environment(\.layoutDirection) private var layoutDirection

  var body: some View {
    let current = SplitLayoutPreset.matching(split.root)
    Menu {
      ForEach(SplitLayoutPreset.available(paneCount: split.tabIDs.count)) { preset in
        Button {
          store.applySplitLayout(preset)
        } label: {
          Label(preset.title, systemImage: current == preset ? "checkmark" : preset.symbol)
        }
      }
      Divider()
      if let selected = store.session.selectedSpace.selectedTabID {
        Button(ShellL10n.string("New Tab to the Right")) {
          store.openSplitPane(
            beside: selected,
            edge: .forPhysicalRight(isRightToLeft: layoutDirection == .rightToLeft))
        }
        .disabled(store.selectedSplitIsFull)
        Button(ShellL10n.string("New Tab Below")) {
          store.openSplitPane(beside: selected, edge: .bottom)
        }
        .disabled(store.selectedSplitIsFull)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: (current ?? .columns).symbol)
        Text(ShellL10n.plural("%d tabs", count: split.tabIDs.count))
      }
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(ShellL10n.string("Split layout"))
    .accessibilityLabel(ShellL10n.string("Split layout"))
  }
}
