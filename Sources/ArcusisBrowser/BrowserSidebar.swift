import BrowserCore
import SwiftUI

struct SidebarFooterBoundsPreferenceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

struct SidebarRevealFrames: Equatable {
  var selected: CGRect = .zero
  var selectedID: UUID?
  var viewport: CGRect = .zero
}

struct SidebarOrdinaryRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    let next = nextValue()
    if !next.selected.isEmpty {
      value.selected = next.selected
      value.selectedID = next.selectedID
    }
    if !next.viewport.isEmpty { value.viewport = next.viewport }
  }
}

struct SidebarFavoriteRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    let next = nextValue()
    if !next.selected.isEmpty {
      value.selected = next.selected
      value.selectedID = next.selectedID
    }
    if !next.viewport.isEmpty { value.viewport = next.viewport }
  }
}

struct SidebarSpaceRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    let next = nextValue()
    if !next.selected.isEmpty {
      value.selected = next.selected
      value.selectedID = next.selectedID
    }
    if !next.viewport.isEmpty { value.viewport = next.viewport }
  }
}

struct BrowserSidebar: View {
  @Bindable var store: BrowserStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides
  @State private var pagerState = SpacePagerState()
  @State private var targetedTab: UUID?
  @State private var targetedSpace: UUID?
  @State private var targetedSection: String?
  @State private var targetedFolder: UUID?
  @State private var hoveredTabID: UUID?
  @State private var newTabIsHovered = false
  @State private var recentDownloads: RecentDownloadsPresentation
  @State private var recentDownloadsCloseTask: Task<Void, Never>?
  @State private var folderDraft: SidebarFolderDraft?
  @FocusState private var folderNameIsFocused: Bool
  let previewRecentDownloads: [BrowserDownload]?

  private var activeSidebarPageID: UUID? {
    guard let page = store.session.selectedPage else { return nil }
    return switch page {
    case .tab(let tab): tab.id
    case .favorite(let favorite): favorite.favoriteID
    }
  }

  private var sidebarReduceMotion: Bool {
    reduceMotion || accessibilityOverrides.reduceMotion == true
  }

  private var activeSidebarSelectionKey: String {
    let kind: String
    switch store.session.selectedPage {
    case .tab?: kind = "tab"
    case .favorite?: kind = "favorite"
    case nil: kind = "none"
    }
    return
      "\(store.session.selectedSpaceID.uuidString):\(kind):\(activeSidebarPageID?.uuidString ?? "none")"
  }

  private func scheduleSelectedPageReveal(_ proxy: ScrollViewProxy, selectionKey: String) {
    DispatchQueue.main.async {
      DispatchQueue.main.async {
        guard selectionKey == activeSidebarSelectionKey,
          case .tab(let tab) = store.session.selectedPage
        else { return }
        if sidebarReduceMotion {
          proxy.scrollTo(tab.id)
        } else {
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(tab.id) }
        }
      }
    }
  }

  private func scheduleSpaceReveal(_ proxy: ScrollViewProxy, id: UUID) {
    DispatchQueue.main.async {
      guard id == store.session.selectedSpaceID else { return }
      if sidebarReduceMotion {
        proxy.scrollTo(id)
      } else {
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
      }
    }
  }

  init(
    store: BrowserStore, previewRecentDownloads: [BrowserDownload]? = nil,
    previewFolderDraft: SidebarFolderDraft? = nil
  ) {
    self.store = store
    self.previewRecentDownloads = previewRecentDownloads
    _recentDownloads = State(
      initialValue: RecentDownloadsPresentation(profileID: store.session.selectedSpace.profileID))
    _folderDraft = State(initialValue: previewFolderDraft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button {
          store.sidebarIsVisible = false
        } label: {
          Image(systemName: "sidebar.left")
        }
        .help("Hide sidebar (Command-S)")
        if let engine = store.engine, let id = store.session.selectedPage?.tab.id {
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
      }
      .font(.system(size: 13))
      SidebarAddressField(store: store)
      profileFavorites
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Label(store.session.selectedSpace.name, systemImage: store.session.selectedSpace.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .contextMenu {
          Button("New Folder", systemImage: "folder.badge.plus") {
            beginFolderDraft(parentID: nil)
          }
          Button("Edit Space…", systemImage: "slider.horizontal.3") {
            store.spaceEditor = .edit(store.session.selectedSpaceID)
          }
        }
        .accessibilityLabel("\(store.session.selectedSpace.name), Profile: \(store.profileName)")
        .help("Space: \(store.session.selectedSpace.name) · Profile: \(store.profileName)")
        if let notice = store.sidebarNotice {
          Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }
      SpacePager(store: store, state: pagerState, reduceMotion: sidebarReduceMotion) { space in
        tabList(space)
      }
      Spacer(minLength: 0)
      Divider()
      HStack(spacing: 8) {
        recentDownloadsControls
          .frame(height: 30)
        spaceSelectors
        Button {
          store.spaceEditor = .create
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
        .help("Create a space")
        .accessibilityLabel("Add Space")
      }
      .frame(height: 32)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarFooterBoundsPreferenceKey.self,
            value: geometry.frame(in: .named("sidebarBounds")))
        }
      }
      .accessibilityIdentifier("sidebar-space-footer")
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .padding(.top, 4)
    .padding(.bottom, 10)
    .background { SpaceSwipeNavigation(store: store, pager: pagerState) }
    .coordinateSpace(name: "sidebarBounds")
    .background {
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
        .animation(
          sidebarReduceMotion ? nil : .easeOut(duration: 0.18),
          value: SpaceChromeTint(space: store.session.selectedSpace))
    }
    .animation(sidebarReduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.22), value: store.session.selectedSpaceID)
    .zIndex(1)
    .onChange(of: store.session.selectedSpaceID) { _, _ in folderDraft = nil }
    .onAppear {
      if folderDraft != nil { folderNameIsFocused = true }
    }
  }

  private func tabList(_ space: BrowserSpace) -> some View {
    let tabIndex = SidebarTabIndex(tabs: space.tabs)
    return ScrollViewReader { tabScroll in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          sectionDropTarget(
            pinned: true,
            height: space.pinnedItems().isEmpty ? 8 : 12)
          if let folderDraft, folderDraft.parentID == nil { folderDraftRow(depth: 0) }
          ForEach(space.pinnedItems()) { item in
            switch item {
            case .folder(let folder, let depth):
              folderRow(folder, depth: depth)
              if let folderDraft, folderDraft.parentID == folder.id {
                folderDraftRow(depth: depth + 1)
              }
            case .tab(let tab, let depth):
              tabRow(tab, index: tabIndex)
                .padding(.leading, indentation(depth))
                .id(tab.id)
                .background {
                  if tab.id == activeSidebarPageID {
                    GeometryReader { geometry in
                      Color.clear.preference(
                        key: SidebarOrdinaryRevealFramesPreferenceKey.self,
                        value: SidebarRevealFrames(
                          selected: geometry.frame(in: .named("sidebarOrdinaryViewport")),
                          selectedID: tab.id))
                    }
                  }
                }
            }
          }
          if space.tabs.contains(where: \.isPinned)
            || !space.folders.isEmpty
          {
            HStack(spacing: 8) {
              Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
              Button("Clear") {
                guard store.session.selectedSpaceID == space.id else { return }
                let ids = space.tabs.filter { !$0.isPinned }.map(\.id)
                for id in ids { store.closeTab(id) }
              }
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .disabled(!space.tabs.contains { !$0.isPinned })
              .help("Close today's tabs")
            }
            .padding(.vertical, 6)
          }
          Button {
            store.showCommand()
          } label: {
            HStack(spacing: 9) {
              Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
              Text("New tab")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .background(
              newTabIsHovered ? Color.primary.opacity(0.07) : .clear,
              in: RoundedRectangle(cornerRadius: 8)
            )
          }
          .accessibilityLabel("New tab")
          .onHover { newTabIsHovered = $0 }
          .animation(sidebarReduceMotion ? nil : .easeOut(duration: 0.12), value: newTabIsHovered)
          .contextMenu {
            Button("Reopen last closed tab") { store.reopenLastClosedTab() }
              .disabled(!store.canReopenClosedTab)
            Button("Recently closed…") { store.showRecentlyClosed() }
          }
          sectionDropTarget(pinned: false)
          ForEach(space.tabs.filter { !$0.isPinned }) { tab in
            tabRow(tab, index: tabIndex)
              .id(tab.id)
              .background {
                if tab.id == activeSidebarPageID {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: SidebarOrdinaryRevealFramesPreferenceKey.self,
                      value: SidebarRevealFrames(
                        selected: geometry.frame(in: .named("sidebarOrdinaryViewport")),
                        selectedID: tab.id))
                  }
                }
              }
          }
          sectionDropTarget(pinned: false, isFooter: true)
        }
      }
      .coordinateSpace(name: "sidebarOrdinaryViewport")
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarOrdinaryRevealFramesPreferenceKey.self,
            value: SidebarRevealFrames(
              viewport: CGRect(origin: .zero, size: geometry.size)))
        }
      }
      .onAppear { scheduleSelectedPageReveal(tabScroll, selectionKey: activeSidebarSelectionKey) }
      .onChange(of: activeSidebarSelectionKey) { _, selectionKey in
        scheduleSelectedPageReveal(tabScroll, selectionKey: selectionKey)
      }
    }
  }

  private var spaceSelectors: some View {
    ScrollViewReader { spaceScroll in
      GeometryReader { geometry in
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(store.session.spaces) { space in
              spaceSelector(space)
            }
          }
          .frame(minWidth: geometry.size.width)
        }
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: .infinity)
      .coordinateSpace(name: "sidebarSpaceViewport")
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarSpaceRevealFramesPreferenceKey.self,
            value: SidebarRevealFrames(
              viewport: CGRect(origin: .zero, size: geometry.size)))
        }
      }
      .onAppear { scheduleSpaceReveal(spaceScroll, id: store.session.selectedSpaceID) }
      .onChange(of: store.session.selectedSpaceID) { _, id in
        scheduleSpaceReveal(spaceScroll, id: id)
      }
    }
  }

  private func spaceSelector(_ space: BrowserSpace) -> some View {
    Button {
      store.perform(.space(space.id))
    } label: {
      Image(systemName: space.symbol)
        .font(.system(size: 14))
        .frame(width: 32, height: 30)
        .foregroundStyle(space.id == store.session.selectedSpaceID ? space.themeColor : Color.primary)
        .background(
          .white.opacity(space.id == store.session.selectedSpaceID ? 0.5 : 0),
          in: RoundedRectangle(cornerRadius: 8)
        )
    }
    .help(space.name)
    .accessibilityLabel("Switch to \(space.name)")
    .accessibilityAddTraits(
      space.id == store.session.selectedSpaceID ? .isSelected : []
    )
    .id(space.id)
    .background {
      if space.id == store.session.selectedSpaceID {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarSpaceRevealFramesPreferenceKey.self,
            value: SidebarRevealFrames(
              selected: geometry.frame(in: .named("sidebarSpaceViewport")),
              selectedID: space.id))
        }
      }
    }
    .draggable(SidebarTransfer.space(sessionID: store.dragSessionID, spaceID: space.id))
    .dropDestination(for: SidebarTransfer.self) { items, point in
      guard items.count == 1, let item = items.first else { return false }
      let spaces = store.session.spaces
      let index = spaces.firstIndex { $0.id == space.id }
      let next = index.flatMap {
        spaces.indices.contains($0 + 1) ? spaces[$0 + 1].id : nil
      }
      return store.acceptSidebarDrop(
        item, into: space.id,
        beforeSpace: point.x < 16 ? space.id : next)
    } isTargeted: { targeted in
      targetedSpace =
        targeted ? space.id : targetedSpace == space.id ? nil : targetedSpace
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

  private var profileFavorites: some View {
    let profileID = store.session.selectedSpace.profileID
    let favorites = store.profileFavorites.map { favorite in
      let page = store.session.favoritePages.first { $0.favoriteID == favorite.id }
      return FavoriteTile(
        id: favorite.id, title: favorite.title, url: page?.tab.url ?? favorite.originalURL,
        image: page.flatMap { store.engine?.favicons[$0.tab.id] })
    }
    return Group {
      if !favorites.isEmpty {
        ProfileFavoritesGrid(
          favorites: favorites,
          selectedID: store.session.selectedSpace.selectedFavoriteID,
          profileID: profileID,
          dragSessionID: store.dragSessionID,
          onSelect: { _ = store.selectFavorite($0) },
          onReset: { _ = store.resetFavorite($0) },
          onRemove: { _ = store.removeFavorite($0) },
          onMoveBefore: { _ = store.moveFavorite($0, before: $1) },
          onTabDrop: { item, before in
            guard case .tab(let sessionID, let source, let tabID) = item,
              sessionID == store.dragSessionID, source == store.session.selectedSpaceID
            else { return false }
            addToFavorites(tabID: tabID, spaceID: source, profileID: profileID)
            guard
              let favoriteID = store.session.favoritePages.first(where: { $0.tab.id == tabID })?
                .favoriteID
            else { return false }
            if let before { _ = store.moveFavorite(favoriteID, before: before) }
            return true
          },
          accessibilityOverrides: ProfileFavoritesAccessibilityOverrides(
            reduceMotion: sidebarReduceMotion,
            reduceTransparency: reduceTransparency
              || accessibilityOverrides.reduceTransparency == true)
        )
      } else {
        Color.clear.frame(height: 8).contentShape(Rectangle())
      }
    }
    .dropDestination(for: SidebarTransfer.self) { items, _ in
      guard items.count == 1, case .tab(let sessionID, let source, let tabID) = items[0],
        sessionID == store.dragSessionID, source == store.session.selectedSpaceID
      else { return false }
      addToFavorites(tabID: tabID, spaceID: source, profileID: profileID)
      return store.session.favoritePages.contains { $0.tab.id == tabID }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.count == 1, NavigationInput.isWebURL(urls[0]), store.sheet == nil,
        !store.commandIsOpen
      else { return false }
      store.perform(.open(urls[0]))
      return store.addCurrentPageAsFavorite()
    }
  }

  private var recentDownloadsControls: some View {
    let profileID = store.session.selectedSpace.profileID
    let downloads = store.engine?.downloads
    let epoch = recentDownloads.epoch
    return HStack(spacing: 2) {
      Button(action: toggleLibraryDrawerFromButton) {
        Image(systemName: "books.vertical")
          .frame(width: 30, height: 30)
      }
      .contextMenu {
        Button("Bookmarks…") { store.showLibrary(.bookmarks) }
        Button("History…") { store.showLibrary(.history) }
      }
      .accessibilityLabel("Library")
      .help("Library")

      Button {
        guard downloadsProfileIsCurrent(profileID), recentDownloads.epoch == epoch,
          store.libraryDrawerSection == nil,
          !store.commandIsOpen, store.sheet == nil
        else { return }
        recentDownloadsCloseTask?.cancel()
        recentDownloads.toggle(profileID: profileID, epoch: epoch)
      } label: {
        Image(systemName: "arrow.down.circle")
          .frame(width: 24, height: 30)
      }
      .disabled(previewRecentDownloads == nil && downloads == nil)
      .accessibilityLabel("Recent downloads")
      .accessibilityHint(
        recentDownloads.isPinned
          ? "Hide recent downloads" : "Show recent downloads for this profile"
      )
      .help("Recent downloads")
    }
    .buttonStyle(.plain)
    .onHover {
      recentDownloadsHoverChanged(.anchor, inside: $0, profileID: profileID, epoch: epoch)
    }
    .overlay(alignment: .bottomLeading) {
      Group {
        if recentDownloads.isOpen || previewRecentDownloads != nil,
          downloadsProfileIsCurrent(profileID),
          let items = previewRecentDownloads ?? downloads?.items(in: profileID)
        {
          RecentDownloadsPopover(
            items: items, profileID: profileID,
            selectedProfileID: { store.session.selectedSpace.profileID },
            dragURL: { item in
              guard previewRecentDownloads == nil, downloadsProfileIsCurrent(profileID),
                recentDownloads.epoch == epoch,
                let downloads
              else { return nil }
              return downloads.fileForDrag(
                id: item.id, profileID: profileID,
                selectedProfileID: store.session.selectedSpace.profileID)
            },
            dismiss: {
              guard downloadsProfileIsCurrent(profileID), recentDownloads.epoch == epoch
              else { return }
              recentDownloadsCloseTask?.cancel()
              recentDownloads.dismiss(profileID: profileID, epoch: epoch)
            }
          )
          .offset(y: -26)
          .onHover {
            recentDownloadsHoverChanged(.card, inside: $0, profileID: profileID, epoch: epoch)
          }
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.14),
        value: recentDownloads.isOpen
      )
      .transaction { transaction in
        if reduceMotion {
          transaction.animation = nil
          transaction.disablesAnimations = true
        }
      }
    }
    .onExitCommand {
      guard downloadsProfileIsCurrent(profileID), recentDownloads.epoch == epoch else { return }
      recentDownloadsCloseTask?.cancel()
      recentDownloads.dismiss(profileID: profileID, epoch: epoch)
    }
    .onChange(of: profileID) { _, newProfileID in
      recentDownloadsCloseTask?.cancel()
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        recentDownloads.selectProfile(newProfileID)
      }
    }
    .onChange(of: store.libraryDrawerSection) { _, section in
      if section != nil { closeRecentDownloadsPreview() }
    }
    .onChange(of: store.commandIsOpen) { _, isOpen in
      if isOpen { closeRecentDownloadsPreview() }
    }
    .onChange(of: store.sheet?.id) { _, sheetID in
      if sheetID != nil { closeRecentDownloadsPreview() }
    }
  }

  private func beginFolderDraft(parentID: UUID?) {
    let route = FolderEditorRoute.create(spaceID: store.session.selectedSpaceID, parentID: parentID)
    guard route.matches(store.session) else { return }
    folderDraft = SidebarFolderDraft(route: route)
    folderNameIsFocused = true
  }

  private func commitFolderDraft() {
    guard let draft = folderDraft, draft.isValid(in: store.session),
      store.createFolder(name: draft.name, in: draft.spaceID, parentID: draft.parentID) != nil
    else { return }
    folderDraft = nil
  }

  private func folderDraftRow(depth: Int) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
      TextField(
        "Untitled",
        text: Binding(
          get: { folderDraft?.name ?? "" },
          set: { folderDraft?.name = $0 }
        )
      )
      .font(.system(size: 13))
      .textFieldStyle(.plain)
      .focused($folderNameIsFocused)
      .onSubmit(commitFolderDraft)
      .onExitCommand { folderDraft = nil }
      Button {
        folderDraft = nil
      } label: {
        Image(systemName: "xmark")
      }
      .font(.system(size: 9, weight: .medium))
      .help("Cancel new folder")
      .accessibilityLabel("Cancel new folder")
    }
    .padding(.vertical, 7).padding(.horizontal, 10)
    .padding(.leading, indentation(depth))
    .background(
      reduceTransparency
        ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .onChange(of: folderDraft?.route) { _, route in
      guard route != nil else { return }
      folderNameIsFocused = true
    }
  }

  private func downloadsProfileIsCurrent(_ profileID: UUID) -> Bool {
    store.session.selectedSpace.profileID == profileID
  }

  private func recentDownloadsHoverChanged(
    _ target: RecentDownloadsPresentation.HoverTarget, inside: Bool, profileID: UUID, epoch: UInt64
  ) {
    guard downloadsProfileIsCurrent(profileID), recentDownloads.epoch == epoch else { return }
    recentDownloadsCloseTask?.cancel()
    guard store.libraryDrawerSection == nil, !store.commandIsOpen, store.sheet == nil else {
      closeRecentDownloadsPreview()
      return
    }
    guard
      let token = recentDownloads.hover(
        target, inside: inside, profileID: profileID, epoch: epoch)
    else { return }
    recentDownloadsCloseTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      guard downloadsProfileIsCurrent(profileID), recentDownloads.epoch == epoch else { return }
      guard store.libraryDrawerSection == nil, !store.commandIsOpen, store.sheet == nil else {
        closeRecentDownloadsPreview()
        return
      }
      recentDownloads.finishHoverLeave(token: token, profileID: profileID, epoch: epoch)
    }
  }

  private func toggleLibraryDrawerFromButton() {
    closeRecentDownloadsPreview()
    _ = store.toggleLibraryDrawer()
  }

  private func closeRecentDownloadsPreview() {
    recentDownloadsCloseTask?.cancel()
    recentDownloads.dismiss(
      profileID: store.session.selectedSpace.profileID, epoch: recentDownloads.epoch)
  }

  private func tabRow(_ tab: BrowserTab, index: SidebarTabIndex) -> some View {
    let space = store.session.selectedSpace
    let boundary = index.boundary(for: tab.id)
    return SidebarTabRow(
      tabID: tab.id,
      title: tab.title,
      favicon: store.engine?.favicons[tab.id],
      isPinned: tab.isPinned,
      isSelected: tab.id == store.session.selectedPage?.tab.id,
      closeIsVisible: hoveredTabID == tab.id,
      onSelect: {
        store.perform(.tab(space: space.id, tab: tab.id))
      },
      onClose: {
        store.closeTab(tab.id)
      },
      onHoverChanged: { isHovered in
        hoveredTabID = isHovered ? tab.id : hoveredTabID == tab.id ? nil : hoveredTabID
      }
    )
    .draggable(
      SidebarTransfer.tab(sessionID: store.dragSessionID, sourceSpaceID: space.id, tabID: tab.id)
    )
    .dropDestination(for: SidebarTransfer.self) { items, point in
      guard items.count == 1, let item = items.first else { return false }
      let sourceID: UUID
      if case .tab(_, _, let id) = item { sourceID = id } else { return false }
      guard let slot = index.dropSlot(targetID: tab.id, sourceID: sourceID, after: point.y >= 17)
      else { return false }
      let before: UUID?
      switch slot {
      case .before(let id): before = id
      case .end: before = nil
      }
      return store.acceptSidebarDrop(
        item, into: space.id, before: before, pinned: tab.isPinned, folderID: tab.folderID)
    } isTargeted: { targeted in
      targetedTab = targeted ? tab.id : targetedTab == tab.id ? nil : targetedTab
    }
    .overlay(alignment: .top) {
      if targetedTab == tab.id { Capsule().fill(Color.accentColor).frame(height: 2) }
    }
    .animation(sidebarReduceMotion ? nil : .easeOut(duration: 0.12), value: targetedTab)
    .dropDestination(for: ProfileFavoriteDrag.self) { items, _ in
      guard items.count == 1 else { return false }
      return moveFavoriteDrop(
        items[0], space: space, before: tab.id, pinned: tab.isPinned, folderID: tab.folderID)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.count == 1 else { return false }
      return openDroppedURL(
        urls[0], space: space, before: tab.id, pinned: tab.isPinned, folderID: tab.folderID)
    }
    .contextMenu {
      Button("Add to Favorites") {
        addToFavorites(tabID: tab.id, spaceID: space.id, profileID: space.profileID)
      }
      .disabled(
        store.sheet != nil || store.commandIsOpen || !NavigationInput.isWebURL(tab.url))
      Divider()
      Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.togglePin(tab.id) }
      Button("Move up") { shiftTab(tab, in: space, by: -1) }.disabled(boundary.isFirst)
      Button("Move down") { shiftTab(tab, in: space, by: 1) }.disabled(boundary.isLast)
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

  private func addToFavorites(tabID: UUID, spaceID: UUID, profileID: UUID) {
    guard store.sheet == nil, !store.commandIsOpen,
      store.session.selectedSpaceID == spaceID,
      let space = store.session.spaces.first(where: { $0.id == spaceID }),
      space.profileID == profileID,
      let tab = space.tabs.first(where: { $0.id == tabID }),
      NavigationInput.isWebURL(tab.url)
    else { return }
    store.perform(.tab(space: spaceID, tab: tabID))
    guard store.session.selectedPage?.tab.id == tabID, store.canFavoriteCurrentPage else { return }
    _ = store.addCurrentPageAsFavorite()
  }

  private func sectionDropTarget(
    pinned: Bool, isFooter: Bool = false, height: CGFloat = 12
  ) -> some View {
    let space = store.session.selectedSpace.id
    let zone = isFooter ? "end" : pinned ? "pinned" : "tabs"
    return Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: isFooter ? 32 : height)
      .contentShape(Rectangle())
      .overlay(alignment: .center) {
        if targetedSection == zone {
          Capsule().fill(Color.accentColor).frame(height: 2)
        }
      }
      .dropDestination(for: SidebarTransfer.self) { items, _ in
        guard items.count == 1, let item = items.first else { return false }
        return store.acceptSidebarDrop(item, into: space, pinned: pinned)
      } isTargeted: { targeted in
        targetedSection = targeted ? zone : targetedSection == zone ? nil : targetedSection
      }
      .dropDestination(for: ProfileFavoriteDrag.self) { items, _ in
        guard items.count == 1 else { return false }
        return moveFavoriteDrop(items[0], space: store.session.selectedSpace, pinned: pinned)
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard urls.count == 1 else { return false }
        return openDroppedURL(urls[0], space: store.session.selectedSpace, pinned: pinned)
      }
      .animation(sidebarReduceMotion ? nil : .easeOut(duration: 0.12), value: targetedSection)
      .accessibilityHidden(true)
  }

  private func moveFavoriteDrop(
    _ payload: ProfileFavoriteDrag, space: BrowserSpace, before: UUID? = nil,
    pinned: Bool, folderID: UUID? = nil
  ) -> Bool {
    guard payload.dragSessionID == store.dragSessionID, payload.profileID == space.profileID,
      payload.favoriteIDs == store.profileFavorites.map(\.id),
      payload.favoriteIDs.contains(payload.favoriteID),
      store.session.selectedSpaceID == space.id, store.selectFavorite(payload.favoriteID),
      let tabID = store.session.favoritePages.first(where: { $0.favoriteID == payload.favoriteID })?
        .tab.id,
      store.removeFavorite(payload.favoriteID)
    else { return false }
    return store.moveTab(
      tabID, from: space.id, to: space.id, before: before, pinned: pinned, folderID: folderID)
  }

  private func openDroppedURL(
    _ url: URL, space: BrowserSpace, before: UUID? = nil, pinned: Bool, folderID: UUID? = nil
  ) -> Bool {
    guard NavigationInput.isWebURL(url), store.session.selectedSpaceID == space.id,
      store.sheet == nil, !store.commandIsOpen
    else { return false }
    store.perform(.open(url))
    guard case .tab(let tab) = store.session.selectedPage else { return false }
    return store.moveTab(
      tab.id, from: space.id, to: space.id, before: before, pinned: pinned, folderID: folderID)
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
    let active =
      space.folderPath(to: store.session.selectedPage?.tab.folderID).contains {
        $0.id == folder.id
      }
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
    .dropDestination(for: ProfileFavoriteDrag.self) { items, _ in
      guard items.count == 1 else { return false }
      return moveFavoriteDrop(items[0], space: space, pinned: true, folderID: folder.id)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.count == 1 else { return false }
      return openDroppedURL(urls[0], space: space, pinned: true, folderID: folder.id)
    }
    .background(
      targetedFolder == folder.id ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contextMenu {
      Button("Edit folder…") {
        store.showFolderEditor(.edit(spaceID: space.id, folderID: folder.id))
      }
      Button("New Folder Inside") { beginFolderDraft(parentID: folder.id) }
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
