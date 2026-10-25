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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "square.grid.2x2")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.secondary)
        Text("Spaces")
          .font(.title3.weight(.semibold))
        Spacer(minLength: 0)
        Text("\(visibleSpaces.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(visibleSpaces.count) Spaces")
      }
      .padding(.horizontal, 20)
      .padding(.top, 18)

      GeometryReader { geometry in
        let width = min(max(geometry.size.width * 0.5, 220), 260)
        ScrollView(.horizontal) {
          LazyHStack(spacing: 14) {
            ForEach(visibleSpaces) { space in
              spaceCard(space)
                .frame(width: width, height: max(0, geometry.size.height - 4))
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Spaces")
      }

      HStack {
        Spacer()
        Button(action: onCreateSpace) {
          Label("Add Space", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.trailing, 20)
        .padding(.bottom, 14)
      }
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
      reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
  }
}

private struct LibrarySpaceCardView: View {
  let store: BrowserStore
  let card: LibrarySpaceCard
  let onSelectSpace: (UUID) -> Void
  let onSelectTab: (UUID, UUID) -> Void
  let onEditSpace: (UUID) -> Void
  let reduceMotion: Bool
  let reduceTransparency: Bool

  private var tint: Color { card.space.themeColor }
  private var isSelected: Bool { store.session.selectedSpaceID == card.space.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      divider
      content
    }
    .background(cardBackground)
    .overlay(cardOutline)
    .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.07), radius: 10, y: 3)
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

  private var divider: some View {
    Rectangle().fill(tint.opacity(0.24)).frame(height: 1).padding(.horizontal, 15)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 18)
      .fill(
        reduceTransparency
          ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
          : AnyShapeStyle(.regularMaterial)
      )
      .overlay(RoundedRectangle(cornerRadius: 18).fill(tint.opacity(0.35)))
  }

  private var cardOutline: some View {
    RoundedRectangle(cornerRadius: 18)
      .strokeBorder(
        isSelected ? tint.opacity(0.82) : Color.primary.opacity(0.08),
        lineWidth: isSelected ? 1.5 : 1)
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
    HStack(alignment: .top, spacing: 11) {
      Button {
        guard
          LibrarySpacesOverviewModel.canSelectSpace(
            spaceID: space.id, profileID: space.profileID, in: store.session)
        else { return }
        onSelectSpace(space.id)
      } label: {
        HStack(alignment: .top, spacing: 11) {
          Image(systemName: space.symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text(space.name)
              .font(.headline)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("Space: \(space.name)")
            Text(profileName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
              .accessibilityLabel("Profile: \(profileName)")
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Select \(space.name)")
      .accessibilityLabel("Select Space \(space.name), Profile \(profileName)")
      Spacer(minLength: 2)
      Button {
        guard
          LibrarySpacesOverviewModel.canEdit(
            spaceID: space.id, profileID: space.profileID, in: store.session)
        else { return }
        onEditSpace(space.id)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Edit \(space.name)")
      .accessibilityLabel("Edit \(space.name)")
    }
    .padding(.horizontal, 15)
    .padding(.top, 15)
    .padding(.bottom, 12)
  }
}

private struct LibrarySpaceItemsView: View {
  let store: BrowserStore
  let card: LibrarySpaceCard
  let tint: Color
  let onSelectTab: (UUID, UUID) -> Void

  var body: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(card.items) { item in row(item) }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
    }
    .scrollIndicators(.automatic)
    .accessibilityLabel("Tabs and folders in \(card.space.name)")
  }

  @ViewBuilder
  private func row(_ item: LibrarySpaceCardItem) -> some View {
    switch item {
    case .folder(let folder, let depth):
      HStack(spacing: 8) {
        Image(systemName: "folder.fill").foregroundStyle(tint).frame(width: 16)
        Text(folder.name)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.leading, min(CGFloat(depth) * 13, 52))
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .accessibilityLabel("Folder: \(folder.name)")
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
          .font(.system(size: 12)).lineLimit(1)
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
