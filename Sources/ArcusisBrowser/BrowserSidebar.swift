import BrowserCore
import SwiftUI

struct BrowserSidebar: View {
  @Bindable var store: BrowserStore
  @State private var targetedTab: UUID?
  @State private var targetedSpace: UUID?
  @State private var targetedSection: String?
  @State private var targetedFolder: UUID?
  @State private var recentDownloadsIsOpen = false
  @State private var recentDownloadsPinnedOpen = false
  @State private var recentDownloadsAnchorHovered = false
  @State private var recentDownloadsCardHovered = false
  @State private var recentDownloadsCloseTask: Task<Void, Never>?
  let previewRecentDownloads: [BrowserDownload]?

  init(store: BrowserStore, previewRecentDownloads: [BrowserDownload]? = nil) {
    self.store = store
    self.previewRecentDownloads = previewRecentDownloads
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      WindowDragRegion()
        .frame(height: 22)
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
      HStack(spacing: 14) {
        Button {
          store.sidebarIsVisible = false
        } label: {
          Image(systemName: "sidebar.left")
        }
        .help("Hide sidebar (Command-S)")
        if let engine = store.engine, let id = store.session.selectedSpace.selectedTabID {
          let state = engine.pages[id]
          Button {
            engine.runtime.goBack(inTabID: id.uuidString)
          } label: {
            Image(systemName: "chevron.left")
          }
          .disabled(state?.canGoBack != true)
          .help("Back")
          Button {
            engine.runtime.goForward(inTabID: id.uuidString)
          } label: {
            Image(systemName: "chevron.right")
          }
          .disabled(state?.canGoForward != true)
          .help("Forward")
          Button {
            store.reloadCurrentPage()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(!store.canReloadCurrentPage)
          .help("Reload (Command-R)")
        }
        Spacer(minLength: 0)
        Button {
          store.bookmarkCurrentPage()
        } label: {
          Image(systemName: "star")
        }
        .disabled(!store.canBookmarkCurrentPage)
        .help("Bookmark this page (Command-D)")
        .accessibilityLabel("Bookmark this page")
      }
      .font(.system(size: 13))
      Button {
        store.showCommand()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
          Text(store.session.selectedSpace.selectedTab?.url.host() ?? "Search or enter address")
            .lineLimit(1)
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
          HStack(spacing: 4) {
            sectionDropTarget("Pinned", pinned: true)
            Button {
              store.showFolderEditor(.create(spaceID: store.session.selectedSpaceID, parentID: nil))
            } label: {
              Image(systemName: "folder.badge.plus")
            }
            .help("New folder").accessibilityLabel("New folder").padding(.trailing, 10)
          }
          ForEach(store.session.selectedSpace.pinnedItems()) { item in
            switch item {
            case .folder(let folder, let depth): folderRow(folder, depth: depth)
            case .tab(let tab, let depth): tabRow(tab).padding(.leading, indentation(depth))
            }
          }
          if store.session.selectedSpace.tabs.contains(where: \.isPinned)
            || !store.session.selectedSpace.folders.isEmpty
          {
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
          .contextMenu {
            Button("Reopen last closed tab") { store.reopenLastClosedTab() }
              .disabled(!store.canReopenClosedTab)
            Button("Recently closed…") { store.showRecentlyClosed() }
          }
          sectionDropTarget("Tabs", pinned: false)
          ForEach(store.session.selectedSpace.tabs.filter { !$0.isPinned }) { tab in tabRow(tab) }
          sectionDropTarget("Move to end", pinned: false, isFooter: true)
        }
      }
      Spacer(minLength: 0)
      Divider()
      recentDownloadsControls
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
    .zIndex(1)
  }

  private var recentDownloadsControls: some View {
    let profileID = store.session.selectedSpace.profileID
    let downloads = store.engine?.downloads
    return HStack(spacing: 8) {
      Menu {
        Button("Bookmarks…") { store.showLibrary(.bookmarks) }
        Button("History…") { store.showLibrary(.history) }
        Button("Downloads…") { store.showDownloads() }
      } label: {
        Label("Library", systemImage: "books.vertical")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .help("Bookmarks and History for \(store.profileName) profile")
      Button {
        guard downloadsProfileIsCurrent(profileID) else { return }
        recentDownloadsCloseTask?.cancel()
        if recentDownloadsIsOpen {
          recentDownloadsPinnedOpen = false
          recentDownloadsIsOpen = false
        } else {
          recentDownloadsPinnedOpen = true
          recentDownloadsIsOpen = true
        }
      } label: {
        Image(systemName: "arrow.down.circle")
          .frame(width: 30, height: 26)
          .contentShape(Rectangle())
      }
      .help("Recent downloads")
      .accessibilityLabel("Toggle recent downloads")
      .accessibilityHint("Shows the five most recent downloads for this profile")
    }
    .font(.system(size: 12))
    .onHover { recentDownloadsAnchorHoverChanged($0) }
    .overlay(alignment: .bottomLeading) {
      if recentDownloadsIsOpen || previewRecentDownloads != nil,
        downloadsProfileIsCurrent(profileID),
        let items = previewRecentDownloads ?? downloads?.items(in: profileID)
      {
        RecentDownloadsPopover(
          items: items, profileID: profileID,
          selectedProfileID: { store.session.selectedSpace.profileID },
          dragURL: { item in
            guard previewRecentDownloads == nil, downloadsProfileIsCurrent(profileID),
              let downloads
            else { return nil }
            return downloads.fileForDrag(
              id: item.id, profileID: profileID,
              selectedProfileID: store.session.selectedSpace.profileID)
          },
          dismiss: {
            guard downloadsProfileIsCurrent(profileID) else { return }
            recentDownloadsPinnedOpen = false
            recentDownloadsIsOpen = false
          }
        )
        .offset(y: -26)
        .onHover { recentDownloadsCardHoverChanged($0) }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .onExitCommand {
      recentDownloadsPinnedOpen = false
      recentDownloadsIsOpen = false
    }
    .onChange(of: profileID) { _, _ in
      recentDownloadsCloseTask?.cancel()
      recentDownloadsPinnedOpen = false
      recentDownloadsAnchorHovered = false
      recentDownloadsCardHovered = false
      recentDownloadsIsOpen = false
    }
  }

  private func downloadsProfileIsCurrent(_ profileID: UUID) -> Bool {
    store.session.selectedSpace.profileID == profileID
  }

  private func recentDownloadsAnchorHoverChanged(_ inside: Bool) {
    recentDownloadsAnchorHovered = inside
    recentDownloadsHoverChanged(inside)
  }

  private func recentDownloadsCardHoverChanged(_ inside: Bool) {
    recentDownloadsCardHovered = inside
    recentDownloadsHoverChanged(inside)
  }

  private func recentDownloadsHoverChanged(_ inside: Bool) {
    recentDownloadsCloseTask?.cancel()
    if inside {
      recentDownloadsIsOpen = true
      return
    }
    recentDownloadsCloseTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      if !recentDownloadsAnchorHovered && !recentDownloadsCardHovered && !recentDownloadsPinnedOpen
      {
        recentDownloadsIsOpen = false
      }
    }
  }

  private func tabRow(_ tab: BrowserTab) -> some View {
    let space = store.session.selectedSpace
    let group = space.tabs.filter { $0.isPinned == tab.isPinned && $0.folderID == tab.folderID }
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
      return store.acceptSidebarDrop(
        item, into: space.id, before: tab.id, pinned: tab.isPinned, folderID: tab.folderID)
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
      Menu("Move to Folder") {
        ForEach(space.folders) { folder in
          Button(folderLabel(folder.id, in: space)) {
            store.moveTab(tab.id, from: space.id, to: space.id, folderID: folder.id)
          }.disabled(tab.folderID == folder.id)
        }
        if tab.folderID != nil {
          Divider()
          Button("Outside folders") {
            store.moveTab(tab.id, from: space.id, to: space.id, pinned: true)
          }
        }
        if space.folders.isEmpty { Text("Create a folder first") }
      }
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
    let group = space.tabs.filter { $0.isPinned == tab.isPinned && $0.folderID == tab.folderID }
    guard let index = group.firstIndex(where: { $0.id == tab.id }),
      group.indices.contains(index + offset)
    else { return }
    let before =
      offset < 0
      ? group[index - 1].id : group.indices.contains(index + 2) ? group[index + 2].id : nil
    store.moveTab(tab.id, from: space.id, to: space.id, before: before, folderID: tab.folderID)
  }

  private func indentation(_ depth: Int) -> CGFloat { CGFloat(min(depth, 12)) * 10 }

  private func folderLabel(_ id: UUID, in space: BrowserSpace) -> String {
    space.folderPath(to: id).reversed().map(\.name).joined(separator: " / ")
  }

  private func folderRow(_ folder: BrowserFolder, depth: Int) -> some View {
    let space = store.session.selectedSpace
    let active = space.folderPath(to: space.selectedTab?.folderID).contains { $0.id == folder.id }
    let siblings = space.folders.filter { $0.parentID == folder.parentID }
    return Button {
      store.toggleFolder(folder.id, in: space.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down").font(
          .system(size: 9, weight: .semibold)
        )
        .frame(width: 10)
        Image(systemName: folder.isCollapsed ? "folder" : "folder.fill").font(.system(size: 12))
        Text(folder.name).font(.system(size: 13, weight: active ? .semibold : .regular)).lineLimit(
          1)
        Spacer(minLength: 0)
        if folder.isCollapsed && active {
          Circle().fill(Color.accentColor).frame(width: 5, height: 5)
        }
      }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
    }
    .padding(.leading, indentation(depth))
    .accessibilityLabel("\(folder.name), \(folder.isCollapsed ? "collapsed" : "expanded")")
    .help(folderLabel(folder.id, in: space))
    .draggable(
      SidebarTransfer.folder(
        sessionID: store.dragSessionID, sourceSpaceID: space.id, folderID: folder.id)
    )
    .dropDestination(for: SidebarTransfer.self) { items, _ in
      guard items.count == 1, let item = items.first else { return false }
      return store.acceptSidebarDrop(item, into: space.id, pinned: true, folderID: folder.id)
    } isTargeted: { targeted in
      targetedFolder = targeted ? folder.id : targetedFolder == folder.id ? nil : targetedFolder
    }
    .background(
      targetedFolder == folder.id ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contextMenu {
      Button("Edit folder…") {
        store.showFolderEditor(.edit(spaceID: space.id, folderID: folder.id))
      }
      Button("New folder inside…") {
        store.showFolderEditor(.create(spaceID: space.id, parentID: folder.id))
      }
      Divider()
      Button("Move up") { shiftFolder(folder, in: space, by: -1) }.disabled(
        siblings.first?.id == folder.id)
      Button("Move down") { shiftFolder(folder, in: space, by: 1) }.disabled(
        siblings.last?.id == folder.id)
      if folder.parentID != nil {
        Button("Move out one level") {
          let parent = space.folders.first { $0.id == folder.parentID }
          store.moveFolder(folder.id, from: space.id, to: space.id, parentID: parent?.parentID)
        }
      }
      Menu("Move to Space") {
        let destinations = store.session.spaces.filter {
          $0.id != space.id && $0.profileID == space.profileID
        }
        if destinations.isEmpty { Text("No other spaces share this profile") }
        ForEach(destinations) { target in
          Button(target.name) { store.moveFolder(folder.id, from: space.id, to: target.id) }
        }
      }
    }
  }

  private func shiftFolder(_ folder: BrowserFolder, in space: BrowserSpace, by offset: Int) {
    let siblings = space.folders.filter { $0.parentID == folder.parentID }
    guard let index = siblings.firstIndex(where: { $0.id == folder.id }),
      siblings.indices.contains(index + offset)
    else { return }
    let before =
      offset < 0
      ? siblings[index - 1].id : siblings.indices.contains(index + 2) ? siblings[index + 2].id : nil
    store.moveFolder(
      folder.id, from: space.id, to: space.id, parentID: folder.parentID, before: before)
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
