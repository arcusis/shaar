import AppKit
import BrowserCore
import SwiftUI

struct LibrarySpacesOverview: View {
  let store: BrowserStore
  let query: String
  let onSelectSpace: (UUID) -> Void
  let onSelectTab: (UUID, UUID) -> Void
  let onEditSpace: (UUID) -> Void
  let onCreateSpace: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  init(
    store: BrowserStore,
    query: String,
    onSelectSpace: @escaping (UUID) -> Void,
    onSelectTab: @escaping (UUID, UUID) -> Void,
    onEditSpace: @escaping (UUID) -> Void,
    onCreateSpace: @escaping () -> Void
  ) {
    self.store = store
    self.query = query
    self.onSelectSpace = onSelectSpace
    self.onSelectTab = onSelectTab
    self.onEditSpace = onEditSpace
    self.onCreateSpace = onCreateSpace
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 24) {
          ForEach(visibleSpaces) { space in
            spaceCard(space)
              .id("\(space.id)-\(query)")
              .frame(width: 280, height: max(0, geometry.size.height - 24))
          }
          Button(action: onCreateSpace) {
            Label("New Space", systemImage: "plus")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("New Space")
          .frame(width: 280, height: max(0, geometry.size.height - 24))
          .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.visible)
      .accessibilityLabel("Spaces")
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var visibleSpaces: [LibrarySpaceCard] {
    LibrarySpacesOverviewModel.cards(in: store.session, query: query)
  }

  private func spaceCard(_ card: LibrarySpaceCard) -> some View {
    LibrarySpaceCardView(
      store: store, card: card, onSelectSpace: onSelectSpace,
      onSelectTab: onSelectTab, onEditSpace: onEditSpace,
      reduceMotion: reduceMotion, colorScheme: colorScheme)
  }
}

private struct LibrarySpaceCardView: View {
  let store: BrowserStore
  let card: LibrarySpaceCard
  let onSelectSpace: (UUID) -> Void
  let onSelectTab: (UUID, UUID) -> Void
  let onEditSpace: (UUID) -> Void
  let reduceMotion: Bool
  let colorScheme: ColorScheme

  private var tint: Color { card.space.themeColor }
  private var isSelected: Bool { store.session.selectedSpaceID == card.space.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      content
      footer
    }
    .background(cardBackground)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
  }

  private var header: some View {
    LibrarySpaceCardHeader(
      store: store, space: card.space, profileName: card.profileName,
      tint: tint, onSelectSpace: onSelectSpace, onEditSpace: onEditSpace)
  }

  @ViewBuilder
  private var content: some View {
    if card.items.isEmpty {
      VStack(spacing: 9) {
        Image(systemName: "rectangle.stack")
          .font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
        Text("No tabs or folders").font(.callout).foregroundStyle(.secondary)
        Text("This Space is ready when you are.")
          .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    } else {
      LibrarySpaceItemsView(store: store, card: card, tint: tint, onSelectTab: onSelectTab)
    }
  }

  private var footer: some View {
    HStack {
      Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        .accessibilityHidden(true)
      Spacer()
      Menu {
        SpaceMenuContent(store: store, space: card.space)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Space options for \(card.space.name)")
    }
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 14)
      .fill(
        isSelected
          ? SpaceChromeTint(space: card.space).color(for: colorScheme)
          : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.05))
  }

}

private struct LibrarySpaceCardHeader: View {
  let store: BrowserStore
  let space: BrowserSpace
  let profileName: String
  let tint: Color
  let onSelectSpace: (UUID) -> Void
  let onEditSpace: (UUID) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button {
        guard
          LibrarySpacesOverviewModel.canSelectSpace(
            spaceID: space.id, profileID: space.profileID, in: store.session)
        else { return }
        onSelectSpace(space.id)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: space.symbol)
            .frame(width: 16)
            .accessibilityHidden(true)
          Text(space.name)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 0)
          Label(profileName, systemImage: "person.fill")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Select \(space.name)")
      .accessibilityLabel("Select Space \(space.name), Profile \(profileName)")
      Button {
        guard
          LibrarySpacesOverviewModel.canEdit(
            spaceID: space.id, profileID: space.profileID, in: store.session)
        else { return }
        onEditSpace(space.id)
      } label: {
        Image(systemName: "pencil")
          .font(.system(size: 12))
          .frame(width: 22, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Edit \(space.name)")
      .accessibilityLabel("Edit \(space.name)")
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 10)
  }
}

private struct LibrarySpaceItemsView: View {
  let store: BrowserStore
  let card: LibrarySpaceCard
  let tint: Color
  let onSelectTab: (UUID, UUID) -> Void
  @State private var collapsedFolders: Set<UUID> = []

  var body: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(visibleItems) { item in
          if case .tab(let tab, _) = item, !tab.isPinned,
            item.id == firstTodayID
          {
            Divider().padding(.vertical, 5)
          }
          row(item)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
    }
    .scrollIndicators(.automatic)
    .accessibilityLabel("Tabs and folders in \(card.space.name)")
  }

  private var firstTodayID: String? {
    card.items.first { item in
      if case .tab(let tab, _) = item { return !tab.isPinned }
      return false
    }?.id
  }

  private var visibleItems: [LibrarySpaceCardItem] {
    var hiddenDepth: Int?
    return card.items.filter { item in
      let depth: Int
      switch item {
      case .folder(_, let value), .tab(_, let value): depth = value
      }
      if let hidden = hiddenDepth {
        if depth > hidden { return false }
        hiddenDepth = nil
      }
      if case .folder(let folder, _) = item, collapsedFolders.contains(folder.id) {
        hiddenDepth = depth
      }
      return true
    }
  }

  @ViewBuilder
  private func row(_ item: LibrarySpaceCardItem) -> some View {
    switch item {
    case .folder(let folder, let depth):
      Button {
        if collapsedFolders.contains(folder.id) {
          collapsedFolders.remove(folder.id)
        } else {
          collapsedFolders.insert(folder.id)
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: collapsedFolders.contains(folder.id) ? "folder" : "folder.fill")
            .frame(width: 16)
          Text(folder.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, min(CGFloat(depth) * 13, 52))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Folder: \(folder.name)")
      .accessibilityValue(collapsedFolders.contains(folder.id) ? "Collapsed" : "Expanded")
    case .tab(let tab, let depth):
      tabButton(tab, depth: depth)
    }
  }

  private func tabButton(_ tab: BrowserTab, depth: Int) -> some View {
    let space = card.space
    let selected =
      store.session.selectedSpaceID == space.id
      && space.selectedFavoriteID == nil && space.selectedTabID == tab.id
    return Button {
      guard
        LibrarySpacesOverviewModel.canSelectTab(
          spaceID: space.id, profileID: space.profileID, tabID: tab.id, in: store.session)
      else { return }
      onSelectTab(space.id, tab.id)
    } label: {
      HStack(spacing: 9) {
        if let favicon = store.engine?.favicons[tab.id] {
          Image(nsImage: favicon).resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
          Image(systemName: tab.isPinned ? "pin.fill" : "globe")
            .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(
            tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? tab.url.absoluteString : tab.title
          )
          .font(.system(size: 14)).lineLimit(1)
        }
        Spacer(minLength: 0)
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13)).foregroundStyle(tint).accessibilityLabel("Selected")
        }
      }
      .padding(.leading, min(CGFloat(depth) * 13, 52))
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .help("\(tab.title)\n\(tab.url.absoluteString)")
    .accessibilityLabel(
      "\(tab.title.isEmpty ? tab.url.absoluteString : tab.title), \(tab.url.absoluteString)"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

enum LibrarySpaceCardItem: Identifiable {
  case folder(BrowserFolder, depth: Int)
  case tab(BrowserTab, depth: Int)

  var id: String {
    switch self {
    case .folder(let folder, _): "folder-\(folder.id)"
    case .tab(let tab, _): "tab-\(tab.id)"
    }
  }
}

struct LibrarySpaceCard: Identifiable {
  let space: BrowserSpace
  let profileName: String
  let items: [LibrarySpaceCardItem]

  var id: UUID { space.id }
}

enum LibrarySpacesOverviewModel {
  static func cards(in session: BrowserSession, query: String) -> [LibrarySpaceCard] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let profiles = Dictionary(uniqueKeysWithValues: session.profiles.map { ($0.id, $0.name) })
    return session.spaces.compactMap { space in
      let profileName = profiles[space.profileID] ?? "Profile"
      let spaceMatches =
        needle.isEmpty || contains(space.name, needle) || contains(profileName, needle)
      var items = space.pinnedItems(includingCollapsed: true).compactMap {
        item -> LibrarySpaceCardItem? in
        switch item {
        case .folder(let folder, let depth): return .folder(folder, depth: depth)
        case .tab(let tab, let depth): return .tab(tab, depth: depth)
        }
      }
      items += space.tabs.filter { !$0.isPinned }.map { .tab($0, depth: 0) }
      if !spaceMatches && !needle.isEmpty {
        let matchingFolderIDs = Set(space.folders.filter { contains($0.name, needle) }.map(\.id))
        items = items.filter { item in
          switch item {
          case .folder(let folder, _):
            return matchingFolderIDs.contains(folder.id)
          case .tab(let tab, _):
            let folderPath = Set(space.folderPath(to: tab.folderID).map(\.id))
            return tabMatches(tab, needle) || !folderPath.isDisjoint(with: matchingFolderIDs)
          }
        }
      }
      if !spaceMatches && items.isEmpty { return nil }
      return LibrarySpaceCard(space: space, profileName: profileName, items: items)
    }
  }

  static func canEdit(spaceID: UUID, profileID: UUID, in session: BrowserSession) -> Bool {
    canSelectSpace(spaceID: spaceID, profileID: profileID, in: session)
  }

  static func canSelectSpace(spaceID: UUID, profileID: UUID, in session: BrowserSession) -> Bool {
    session.spaces.contains { $0.id == spaceID && $0.profileID == profileID }
  }

  static func canSelectTab(
    spaceID: UUID, profileID: UUID, tabID: UUID, in session: BrowserSession
  ) -> Bool {
    session.spaces.contains { space in
      space.id == spaceID && space.profileID == profileID && space.tabs.contains { $0.id == tabID }
    }
  }

  private static func tabMatches(_ tab: BrowserTab, _ query: String) -> Bool {
    contains(tab.title, query) || contains(tab.url.absoluteString, query)
  }

  private static func contains(_ value: String, _ query: String) -> Bool {
    value.localizedStandardContains(query)
  }
}
