// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct CommandPanel: View {
  @Bindable var store: BrowserStore
  let resultsHeight: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var searchIsFocused: Bool
  @State private var movedSelection = false
  @Namespace private var selectionNamespace

  var body: some View {
    VStack(spacing: 0) {
      searchField
      CommandFilterChips(store: store)
      Divider()
      resultsList
      Divider()
      footer
    }
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
    .clipShape(RoundedRectangle(cornerRadius: 17))
    .overlay {
      RoundedRectangle(cornerRadius: 17)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
    .task {
      await Task.yield()
      guard !Task.isCancelled, store.commandIsOpen else { return }
      searchIsFocused = true
      if store.commandEditsCurrentURL {
        await Task.yield()
        if searchIsFocused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
          editor.selectAll(nil)
        }
      }
    }
    .onChange(of: store.commandQuery) { _, _ in
      movedSelection = false
    }
    .onChange(of: store.commandFilter) { _, _ in
      movedSelection = true
    }
    .onKeyPress(.upArrow) {
      moveSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.tab, phases: .down) { press in
      store.cycleCommandFilter(by: press.modifiers.contains(.shift) ? -1 : 1)
      return .handled
    }
    .onKeyPress(.return, phases: .down) { press in
      guard press.modifiers.contains(.command) else { return .ignored }
      acceptCommandInNewTab()
      return .handled
    }
    .onExitCommand { store.dismissCommand() }
    .accessibilityLabel(ShellL10n.string("Search tabs, spaces, or the web"))
  }

  private var searchField: some View {
    HStack(spacing: 14) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 21, weight: .light))
        .foregroundStyle(.secondary)
      TextField(ShellL10n.string("Search or enter address"), text: $store.commandQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 21))
        .focused($searchIsFocused)
        .onSubmit { acceptCommand() }
        .accessibilityIdentifier("command-search")
      ShellL10n.text("esc")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }

  private var resultsList: some View {
    let sections = store.commandSections
    let results = sections.results
    let selection = store.commandSelection
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          if results.isEmpty {
            Text(emptyMessage)
              .foregroundStyle(.secondary)
              .padding(20)
          }
          ForEach(IndexedSection.list(sections)) { item in
            if !item.section.title.isEmpty {
              CommandSectionHeader(title: item.section.title)
            }
            ForEach(Array(item.section.results.enumerated()), id: \.element.id) { offset, result in
              row(result, isSelected: item.start + offset == selection)
            }
          }
        }
        .padding(8)
        // New results replace the rows in place; only the panel's resize animates.
        .transaction(value: results.map(\.id)) { $0.animation = nil }
      }
      .frame(height: resultsHeight)
      .onChange(of: selection) { _, index in
        guard results.indices.contains(index) else { return }
        proxy.scrollTo(results[index].id)
      }
    }
  }

  private var emptyMessage: String {
    let query = store.commandQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty, store.commandFilter == nil { return ShellL10n.string("No suggestions yet") }
    return ShellL10n.string("No matching results")
  }

  private func row(_ result: CommandResult, isSelected: Bool) -> some View {
    CommandResultButton(
      store: store, result: result, subtitle: subtitle(for: result),
      favicon: favicon(for: result.action),
      actionHint: isSelected ? actionLabel(for: result) : nil, isSelected: isSelected,
      selectionNamespace: selectionNamespace
    )
    .id(result.id)
  }

  /// Only keyboard moves animate, so the highlight slides between rows without animating the
  /// rows themselves.
  private func moveSelection(by amount: Int) {
    movedSelection = true
    withAnimation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.1)) {
      store.moveCommandSelection(by: amount)
    }
  }

  private var footer: some View {
    HStack {
      Label(store.profileName, systemImage: "person.crop.circle")
      Spacer()
      ShellL10n.text("⇥ filter    ↑↓ select    ↩ open")
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
  }

  private func acceptCommand() {
    if store.commandEditsCurrentURL, !movedSelection,
      let url = NavigationInput.destination(
        for: store.commandQuery,
        searchEngine: store.preferences.searchEngine(for: store.session.selectedSpace.profileID)),
      store.engine?.navigateCurrentPage(to: url) == true
    {
      store.dismissCommand()
      return
    }
    store.acceptCommand()
  }

  private func acceptCommandInNewTab() {
    guard let action = store.selectedCommandResult?.action else { return }
    if case .tab(_, let tabID) = action, let page = store.session.page(forTabID: tabID) {
      store.perform(.open(page.tab.url))
    } else if store.commandEditsCurrentURL, !movedSelection,
      let url = NavigationInput.destination(
        for: store.commandQuery,
        searchEngine: store.preferences.searchEngine(for: store.session.selectedSpace.profileID))
    {
      store.perform(.open(url))
    } else {
      store.perform(action)
    }
  }

  private func favicon(for action: CommandAction) -> NSImage? {
    let tabID: UUID
    switch action {
    case .tab(_, let id):
      guard store.session.spaces.contains(where: { $0.tabs.contains(where: { $0.id == id }) })
      else { return nil }
      tabID = id
    case .favorite(let profileID, let favoriteID):
      guard
        store.session.favorites.contains(where: { $0.id == favoriteID && $0.profileID == profileID }
        ),
        let page = store.session.favoritePage(for: favoriteID),
        store.session.profileID(forTabID: page.tab.id) == profileID
      else { return nil }
      tabID = page.tab.id
    default:
      return nil
    }
    return store.engine?.favicons[tabID]
  }

  private func subtitle(for result: CommandResult) -> String {
    guard case .tab(let spaceID, _) = result.action,
      let space = store.session.spaces.first(where: { $0.id == spaceID }),
      space.profileID != store.session.selectedSpace.profileID,
      let profile = store.session.profiles.first(where: { $0.id == space.profileID })
    else { return result.subtitle }
    return ShellL10n.format(
      "%@ · %@ profile", arguments: [.string(result.subtitle), .string(profile.name)])
  }

  private func actionLabel(for result: CommandResult) -> String {
    switch result.action {
    case .tab: ShellL10n.string("Switch to Tab")
    case .favorite: ShellL10n.string("Open Favorite")
    case .space: ShellL10n.string("Switch Space")
    case .folder: ShellL10n.string("Open Folder")
    case .reopen: ShellL10n.string("Reopen Tab")
    case .bookmark: ShellL10n.string("Open Bookmark")
    case .history: ShellL10n.string("Open")
    case .command: ShellL10n.string("Run Action")
    case .open(let url):
      ShellL10n.string(isWebSearch(url) ? "Search Web" : "Open")
    }
  }

  private func isWebSearch(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "q" && !($0.value ?? "").isEmpty })
        == true
    else { return false }
    return switch (url.host(), components.path) {
    case ("www.google.com", "/search"), ("www.bing.com", "/search"),
      ("duckduckgo.com", "/"):
      true
    default:
      false
    }
  }
}

/// A launcher row built from values, so moving the selection re-renders only the rows it leaves
/// and enters.
private struct CommandResultButton: View {
  let store: BrowserStore
  let result: CommandResult
  let subtitle: String
  let favicon: NSImage?
  let actionHint: String?
  let isSelected: Bool
  let selectionNamespace: Namespace.ID

  var body: some View {
    Button {
      store.perform(result.action)
    } label: {
      CommandResultRow(
        result: result, subtitle: subtitle, favicon: favicon, actionHint: actionHint
      )
      .background {
        if isSelected { selectionHighlight }
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// One shared highlight that slides between rows as the selection moves.
  private var selectionHighlight: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(Color.accentColor.opacity(0.15))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1)
      }
      .matchedGeometryEffect(id: "selection", in: selectionNamespace)
  }
}

/// A section with the flat index of its first row, so keyboard selection spans sections.
private struct IndexedSection: Identifiable {
  let section: CommandSection
  let start: Int
  var id: String { section.id }

  static func list(_ sections: [CommandSection]) -> [IndexedSection] {
    var start = 0
    return sections.map { section in
      defer { start += section.results.count }
      return IndexedSection(section: section, start: start)
    }
  }
}
