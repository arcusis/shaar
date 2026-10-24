import BrowserCore
import SwiftUI

struct BrowserSidebar: View {
  @Bindable var store: BrowserStore
  @State private var targetedTab: UUID?
  @State private var targetedSpace: UUID?
  @State private var targetedSection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Arcusis").font(.system(size: 13, weight: .semibold, design: .rounded))
        Spacer()
        Button {
          store.spaceEditor = .create
        } label: {
          Image(systemName: "plus")
        }
        .help("Create a space")
      }
      .padding(.top, 42)
      Button {
        store.showCommand()
      } label: {
        HStack {
          Image(systemName: "magnifyingglass")
          Text("Search anything")
          Spacer()
          Text("⌘T").foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
      }
      VStack(alignment: .leading, spacing: 5) {
        Label(store.session.selectedSpace.name, systemImage: store.session.selectedSpace.symbol)
          .font(.system(size: 14, weight: .semibold))
        Text("\(store.profileName) profile")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        if let notice = store.sidebarNotice {
          Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          sectionDropTarget("Pinned", pinned: true)
          ForEach(store.session.selectedSpace.tabs.filter(\.isPinned)) { tab in tabRow(tab) }
          if store.session.selectedSpace.tabs.contains(where: \.isPinned) {
            Divider().padding(.vertical, 10)
          }
          Button {
            store.showCommand()
          } label: {
            Label("New tab", systemImage: "plus")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .padding(10)
          }
          sectionDropTarget("Tabs", pinned: false)
          ForEach(store.session.selectedSpace.tabs.filter { !$0.isPinned }) { tab in tabRow(tab) }
          sectionDropTarget("Move to end", pinned: false, isFooter: true)
        }
      }
      Spacer(minLength: 0)
      Divider()
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(store.session.spaces) { space in
            Button {
              store.perform(.space(space.id))
            } label: {
              Image(systemName: space.symbol)
                .font(.system(size: 14))
                .frame(width: 32, height: 30)
                .background(
                  .white.opacity(space.id == store.session.selectedSpaceID ? 0.5 : 0),
                  in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .help(space.name)
            .accessibilityLabel("Switch to \(space.name)")
            .accessibilityAddTraits(space.id == store.session.selectedSpaceID ? .isSelected : [])
            .draggable(SidebarTransfer.space(sessionID: store.dragSessionID, spaceID: space.id))
            .dropDestination(for: SidebarTransfer.self) { items, point in
              guard items.count == 1, let item = items.first else { return false }
              let spaces = store.session.spaces
              let index = spaces.firstIndex { $0.id == space.id }
              let next = index.flatMap { spaces.indices.contains($0 + 1) ? spaces[$0 + 1].id : nil }
              return store.acceptSidebarDrop(
                item, into: space.id,
                beforeSpace: point.x < 16 ? space.id : next)
            } isTargeted: { targeted in
              targetedSpace = targeted ? space.id : targetedSpace == space.id ? nil : targetedSpace
            }
            .overlay(
              RoundedRectangle(cornerRadius: 8).strokeBorder(
                targetedSpace == space.id ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contextMenu {
              Button("Edit space…") { store.spaceEditor = .edit(space.id) }
              Divider()
              Button("Move left") { shiftSpace(space.id, by: -1) }
                .disabled(store.session.spaces.first?.id == space.id)
              Button("Move right") { shiftSpace(space.id, by: 1) }
                .disabled(store.session.spaces.last?.id == space.id)
            }
          }
        }
      }
      .scrollIndicators(.hidden)
      .frame(height: 32)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .padding(.bottom, 16)
  }

  private func tabRow(_ tab: BrowserTab) -> some View {
    let space = store.session.selectedSpace
    let group = space.tabs.filter { $0.isPinned == tab.isPinned }
    return HStack(spacing: 8) {
      Button {
        store.perform(.tab(space: space.id, tab: tab.id))
      } label: {
        HStack(spacing: 9) {
          Image(systemName: tab.isPinned ? "pin" : "globe")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          Text(tab.title).font(.system(size: 13)).lineLimit(1)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      Button {
        store.closeTab(tab.id)
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
      }
      .help("Close \(tab.title)")
    }
    .padding(10)
    .background(
      .white.opacity(tab.id == store.session.selectedSpace.selectedTabID ? 0.43 : 0),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .draggable(
      SidebarTransfer.tab(sessionID: store.dragSessionID, sourceSpaceID: space.id, tabID: tab.id)
    )
    .dropDestination(for: SidebarTransfer.self) { items, _ in
      guard items.count == 1, let item = items.first else { return false }
      return store.acceptSidebarDrop(item, into: space.id, before: tab.id, pinned: tab.isPinned)
    } isTargeted: { targeted in
      targetedTab = targeted ? tab.id : targetedTab == tab.id ? nil : targetedTab
    }
    .overlay(alignment: .top) {
      if targetedTab == tab.id { Rectangle().fill(Color.accentColor).frame(height: 2) }
    }
    .contextMenu {
      Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.togglePin(tab.id) }
      Button("Move up") { shiftTab(tab, in: space, by: -1) }.disabled(group.first?.id == tab.id)
      Button("Move down") { shiftTab(tab, in: space, by: 1) }.disabled(group.last?.id == tab.id)
      Menu("Move to Space") {
        let destinations = store.session.spaces.filter {
          $0.id != space.id && $0.profileID == space.profileID
        }
        if destinations.isEmpty { Text("No other spaces share this profile") }
        ForEach(destinations) { target in
          Button(target.name) { store.moveTab(tab.id, from: space.id, to: target.id) }
        }
      }
      Divider()
      Button("Close tab") { store.closeTab(tab.id) }
    }
  }

  private func sectionDropTarget(_ label: String, pinned: Bool, isFooter: Bool = false) -> some View
  {
    let space = store.session.selectedSpace.id
    let zone = isFooter ? "end" : pinned ? "pinned" : "tabs"
    return Text(label)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(
        .vertical, 8
      )
      .opacity(isFooter ? 0.6 : 1)
      .contentShape(Rectangle())
      .background(
        targetedSection == zone ? Color.accentColor.opacity(0.16) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .dropDestination(for: SidebarTransfer.self) { items, _ in
        guard items.count == 1, let item = items.first else { return false }
        return store.acceptSidebarDrop(item, into: space, pinned: pinned)
      } isTargeted: { targeted in
        targetedSection = targeted ? zone : targetedSection == zone ? nil : targetedSection
      }
      .accessibilityLabel(isFooter ? "Move tab to end" : "\(label) tabs")
  }

  private func shiftTab(_ tab: BrowserTab, in space: BrowserSpace, by offset: Int) {
    let group = space.tabs.filter { $0.isPinned == tab.isPinned }
    guard let index = group.firstIndex(where: { $0.id == tab.id }),
      group.indices.contains(index + offset)
    else { return }
    let before =
      offset < 0
      ? group[index - 1].id : group.indices.contains(index + 2) ? group[index + 2].id : nil
    store.moveTab(tab.id, from: space.id, to: space.id, before: before)
  }

  private func shiftSpace(_ id: UUID, by offset: Int) {
    let spaces = store.session.spaces
    guard let index = spaces.firstIndex(where: { $0.id == id }),
      spaces.indices.contains(index + offset)
    else { return }
    let before =
      offset < 0
      ? spaces[index - 1].id : spaces.indices.contains(index + 2) ? spaces[index + 2].id : nil
    store.moveSpace(id, before: before)
  }
}
