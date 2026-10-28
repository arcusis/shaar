import BrowserCore
import SwiftUI

/// Back, forward, reload and the address for one pane of a split.
struct SplitPaneToolbar: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?
  let tabID: UUID

  @Environment(\.colorScheme) private var colorScheme

  private var tab: BrowserTab? {
    store.session.selectedSpace.tabs.first { $0.id == tabID }
  }

  private var isFocused: Bool {
    store.session.selectedSpace.selectedTabID == tabID
  }

  var body: some View {
    let state = engine?.pages[tabID]
    HStack(spacing: 2) {
      toolbarButton("chevron.left", label: "Back") {
        engine?.runtime.goBack(inTabID: tabID.uuidString)
      }
      .disabled(state?.canGoBack != true)
      toolbarButton("chevron.right", label: "Forward") {
        engine?.runtime.goForward(inTabID: tabID.uuidString)
      }
      .disabled(state?.canGoForward != true)
      toolbarButton("arrow.clockwise", label: "Reload") {
        focus()
        store.reloadCurrentPage()
      }
      address
      paneMenu
    }
    .padding(.horizontal, 4)
    .frame(height: 30)
    .background(
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
        .opacity(isFocused ? 1 : 0.6))
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
    .accessibilityLabel("Address \(tab?.url.host() ?? "")")
  }

  private var paneMenu: some View {
    Menu {
      Button("New Tab to the Right") { store.openSplitPane(beside: tabID, edge: .right) }
        .disabled(store.selectedSplitIsFull)
      Button("New Tab Below") { store.openSplitPane(beside: tabID, edge: .bottom) }
        .disabled(store.selectedSplitIsFull)
      Divider()
      Button("Separate from Split") { store.unsplitTab(tabID) }
      Button("Close Tab") { store.closeTab(tabID) }
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
    .help("Pane options")
    .accessibilityLabel("Pane options")
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
        Button("New Tab to the Right") { store.openSplitPane(beside: selected, edge: .right) }
          .disabled(store.selectedSplitIsFull)
        Button("New Tab Below") { store.openSplitPane(beside: selected, edge: .bottom) }
          .disabled(store.selectedSplitIsFull)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: (current ?? .columns).symbol)
        Text("\(split.tabIDs.count) tabs")
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
    .help("Split layout")
    .accessibilityLabel("Split layout")
  }
}
