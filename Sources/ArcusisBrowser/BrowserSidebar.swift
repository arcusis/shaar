// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct FavoritePageIndex {
  private let pagesByFavoriteID: [UUID: BrowserFavoritePage]

  init(_ pages: [BrowserFavoritePage]) {
    pagesByFavoriteID = Dictionary(
      pages.lazy.map { ($0.favoriteID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func page(for favoriteID: UUID) -> BrowserFavoritePage? {
    pagesByFavoriteID[favoriteID]
  }
}

struct BrowserSidebar: View {
  static let pinnedSectionHeadingTraits: AccessibilityTraits = .isHeader
  static let currentTabsSectionHeadingTraits: AccessibilityTraits = .isHeader

  static func currentTabsSectionLabel(
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.string("Today's tabs", table: "Shell", language: language)
  }

  static func accessibilityGroupLabel(
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.string("Browser sidebar", table: "Shell", language: language)
  }

  @Bindable var store: BrowserStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.browserWindowIsFullScreen) private var isFullScreen
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides
  @Namespace private var sidebarMotionNamespace
  @State private var pagerState: SpacePagerState
  @State private var targetedTab: UUID?
  @State private var targetedSpace: UUID?
  @State private var targetedSection: String?
  @State private var targetedFolder: UUID?
  @State private var folderHoverDelay = SidebarFolderHoverDelay()
  @State private var folderHoverTab: UUID?
  @State private var folderHoverSession: DropSession.ID?
  @State private var folderHoverDeadline: ContinuousClock.Instant?
  @State private var folderDropReady: UUID?
  @State private var targetedTabIntent: SidebarTabDropIntent?
  @State private var hoveredTabID: UUID?
  @State private var newTabIsHovered = false
  @State private var recentDownloads: RecentDownloadsPresentation
  @State private var folderDraft: SidebarFolderDraft?
  @State private var clearSpaceID: UUID?
  @State private var tidyInProgress = false
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

  private var sidebarMotion: Animation? {
    sidebarReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)
  }

  private var sidebarLayoutKey: SidebarLayoutKey {
    SidebarLayoutKey(
      favorites: store.profileFavorites,
      folders: store.session.selectedSpace.folders,
      tabs: store.session.selectedSpace.tabs)
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
        let reveal = {
          if store.session.selectedSpace.tabs.last(where: { !$0.isPinned })?.id == tab.id {
            proxy.scrollTo(tab.id, anchor: .top)
          } else {
            proxy.scrollTo(tab.id)
          }
        }
        if sidebarReduceMotion {
          reveal()
        } else {
          withAnimation(.easeOut(duration: 0.12), reveal)
        }
      }
    }
  }

  init(
    store: BrowserStore, previewRecentDownloads: [BrowserDownload]? = nil,
    previewFolderDraft: SidebarFolderDraft? = nil, pagerState: SpacePagerState? = nil
  ) {
    self.store = store
    self.previewRecentDownloads = previewRecentDownloads
    _pagerState = State(initialValue: pagerState ?? SpacePagerState())
    _recentDownloads = State(
      initialValue: RecentDownloadsPresentation(profileID: store.session.selectedSpace.profileID))
    _folderDraft = State(initialValue: previewFolderDraft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      profileFavorites
        .id(
          sidebarReduceMotion
            ? SidebarLayoutIdentity.layout(sidebarLayoutKey) : .constant("favorites"))
        .transition(.opacity)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Label(store.session.selectedSpace.name, systemImage: store.session.selectedSpace.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .contextMenu {
          SpaceMenuContent(store: store, space: store.session.selectedSpace)
        }
        .accessibilityLabel(
          ShellL10n.format(
            "%@, Profile: %@",
            arguments: [.string(store.session.selectedSpace.name), .string(store.profileName)])
        )
        .help(
          ShellL10n.format(
            "Space: %@ · Profile: %@",
            arguments: [.string(store.session.selectedSpace.name), .string(store.profileName)]))
        if let notice = store.sidebarNotice {
          Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }
      SpacePager(store: store, state: pagerState, reduceMotion: sidebarReduceMotion) { space in
        tabList(space)
          .id(
            sidebarReduceMotion
              ? SidebarLayoutIdentity.layout(sidebarLayoutKey) : .constant("tabs"))
          .transition(.opacity)
      }
      Spacer(minLength: 0)
      if let item = store.miniPlayerItem {
        SidebarMediaPlayer(
          item: item, onSelect: { store.selectPage(item.tabID) },
          onCommand: { store.performMedia($0, tabID: item.tabID) }
        )
        .transition(.opacity)
      }
      Divider()
      HStack(spacing: 8) {
        recentDownloadsControls
          .frame(height: 30)
        spaceSelectors
        Menu {
          Button(ShellL10n.string("New Folder")) { beginFolderDraft(parentID: nil) }
          Button(ShellL10n.string("New Space")) { store.spaceEditor = .create }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 16))
            .foregroundStyle(Color.primary.opacity(0.55))
            .frame(width: 30, height: 30)
        }
        .help(ShellL10n.string("Create a folder or space"))
        .accessibilityLabel(ShellL10n.string("Add Folder or Space"))
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Self.accessibilityGroupLabel())
    .environment(\.sidebarMotionNamespace, sidebarMotionNamespace)
    .animation(sidebarMotion, value: sidebarLayoutKey)
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .padding(.top, isFullScreen ? BrowserChromeLayout.fullScreenToggleRowHeight : 4)
    .padding(.bottom, 10)
    .background { SpaceSwipeNavigation(store: store, pager: pagerState) }
    .coordinateSpace(name: "sidebarBounds")
    .background {
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
        .animation(
          sidebarReduceMotion ? nil : .easeOut(duration: 0.18),
          value: SpaceChromeTint(space: store.session.selectedSpace))
    }
    .animation(
      sidebarReduceMotion ? nil : .easeInOut(duration: 0.22),
      value: store.session.selectedSpaceID
    )
    .zIndex(1)
    .onChange(of: store.session.selectedSpaceID) { _, _ in
      folderDraft = nil
      cancelFolderHover()
    }
    .onDisappear { cancelFolderHover() }
    .onAppear {
      if folderDraft != nil { folderNameIsFocused = true }
    }
  }

  private func tabList(_ space: BrowserSpace) -> some View {
    let tabIndex = SidebarTabIndex(tabs: space.tabs)
    let folderSiblingIndex = SidebarFolderSiblingIndex(folders: space.folders)
    return ScrollViewReader { tabScroll in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          HStack {
            ShellL10n.text("Pinned").font(.system(size: 11, weight: .semibold))
              .accessibilityAddTraits(Self.pinnedSectionHeadingTraits)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              beginFolderDraft(parentID: nil)
            } label: {
              Image(systemName: "folder.badge.plus").frame(width: 26, height: 26)
            }
            .help(ShellL10n.string("New Folder"))
            .accessibilityLabel(ShellL10n.string("New Folder"))
            .accessibilityIdentifier("sidebar-pinned-new-folder")
          }
          sectionDropTarget(
            pinned: true,
            height: space.pinnedItems().isEmpty ? 8 : 12,
            hint: space.pinnedItems().isEmpty
              ? ShellL10n.string("Drop to pin in this Space") : nil)
          if let folderDraft, folderDraft.section == .pinned, folderDraft.parentID == nil,
            folderDraft.editingFolderID == nil
          {
            folderDraftRow(depth: 0)
          }
          ForEach(space.pinnedItems()) { item in
            switch item {
            case .folder(let folder, let depth):
              if folderDraft?.editingFolderID == folder.id {
                folderDraftRow(depth: depth)
              } else {
                folderRow(folder, depth: depth, siblingIndex: folderSiblingIndex)
              }
              if let folderDraft, folderDraft.editingFolderID == nil,
                folderDraft.parentID == folder.id
              {
                folderDraftRow(depth: depth + 1)
              }
            case .tab(let tab, let depth):
              if isSplitRowLeader(tab, in: space) {
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
          }
          LazyVStack(alignment: .leading, spacing: 4) {
            if !space.tabs.isEmpty || !space.folders.isEmpty {
              HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                Button(ShellL10n.string("Tidy")) { tidyTabs(in: space) }
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.secondary)
                  .disabled(tidyInProgress || !space.tabs.contains { !$0.isPinned })
                  .help(ShellL10n.string("Group today's tabs by topic"))
                Button(ShellL10n.string("Clear")) {
                  clearSpaceID = space.id
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .disabled(!space.tabs.contains { !$0.isPinned })
                .help(ShellL10n.string("Close today's tabs"))
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
                ShellL10n.text("New tab")
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
            .accessibilityLabel(ShellL10n.string("New tab"))
            .onHover { newTabIsHovered = $0 }
            .animation(sidebarReduceMotion ? nil : .easeOut(duration: 0.12), value: newTabIsHovered)
            .contextMenu {
              Button(ShellL10n.string("New Folder")) {
                beginFolderDraft(parentID: nil, section: .today)
              }
              Button(ShellL10n.string("Reopen last closed tab")) { store.reopenLastClosedTab() }
                .disabled(!store.canReopenClosedTab)
              Button(ShellL10n.string("Recently closed…")) { store.showRecentlyClosed() }
            }
            sectionDropTarget(pinned: false)
            if let folderDraft, folderDraft.section == .today, folderDraft.parentID == nil,
              folderDraft.editingFolderID == nil
            {
              folderDraftRow(depth: 0)
            }
            ForEach(space.items(isPinned: false)) { item in
              switch item {
              case .folder(let folder, let depth):
                if folderDraft?.editingFolderID == folder.id {
                  folderDraftRow(depth: depth)
                } else {
                  folderRow(folder, depth: depth, siblingIndex: folderSiblingIndex)
                }
                if let folderDraft, folderDraft.editingFolderID == nil,
                  folderDraft.parentID == folder.id
                {
                  folderDraftRow(depth: depth + 1)
                }
              case .tab(let tab, _):
                if isSplitRowLeader(tab, in: space) {
                  tabRow(tab, index: tabIndex).id(tab.id)
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
            }
            sectionDropTarget(pinned: false, isFooter: true)
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Self.currentTabsSectionLabel())
          .accessibilityAddTraits(Self.currentTabsSectionHeadingTraits)
        }
      }
      .contextMenu {
        Button(ShellL10n.string("New Folder")) { beginFolderDraft(parentID: nil, section: .today) }
      }
      .confirmationDialog(
        ShellL10n.string("Close today's tabs?"),
        isPresented: Binding(
          get: { clearSpaceID == space.id },
          set: { if !$0 { clearSpaceID = nil } }
        ), titleVisibility: .visible
      ) {
        Button(ShellL10n.string("Close Tabs"), role: .destructive) {
          guard store.session.selectedSpaceID == space.id else { return }
          store.clearTodayTabs(in: space.id)
          clearSpaceID = nil
        }
      } message: {
        ShellL10n.text("Pinned tabs and favorites will be kept.")
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
    GeometryReader { geometry in
      let spaces = store.session.spaces
      let selected = spaces.firstIndex { $0.id == store.session.selectedSpaceID } ?? 0
      let layout = SpaceIndicatorLayout(
        count: spaces.count, selectedIndex: selected, width: geometry.size.width)
      HStack(spacing: 0) {
        ForEach(Array(spaces[layout.visible])) { space in
          spaceSelector(
            space,
            width: space.id == store.session.selectedSpaceID
              ? layout.selectedWidth : layout.dotWidth)
        }
        if layout.overflowWidth > 0 {
          Menu {
            ForEach(spaces) { space in
              Button {
                store.perform(.space(space.id))
              } label: {
                Label(space.name, systemImage: space.symbol)
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 12))
              .frame(width: layout.overflowWidth, height: 30)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help(ShellL10n.string("More Spaces"))
          .accessibilityLabel(ShellL10n.string("More Spaces"))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
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
  }

  private func spaceSelector(_ space: BrowserSpace, width: CGFloat) -> some View {
    Button {
      store.perform(.space(space.id))
    } label: {
      Group {
        if space.id == store.session.selectedSpaceID {
          Image(systemName: space.symbol)
            .font(.system(size: 14))
            .foregroundStyle(Color.primary)
        } else {
          Circle()
            .fill(Color.primary.opacity(0.35))
            .frame(width: 6, height: 6)
        }
      }
      .frame(width: width, height: 30)
      .contentShape(Rectangle())
    }
    .help(space.name)
    .accessibilityLabel(ShellL10n.format("Switch to %@", arguments: [.string(space.name)]))
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
      let beforeTarget = SpaceIndicatorLayout.insertsBeforeTarget(
        at: point.x, width: width, isRightToLeft: layoutDirection == .rightToLeft)
      return store.acceptSidebarDrop(
        item, into: space.id,
        beforeSpace: beforeTarget ? space.id : next)
    } isTargeted: { targeted in
      targetedSpace = targetedSpace.updatingTarget(space.id, isActive: targeted)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        targetedSpace == space.id ? Color.accentColor : .clear, lineWidth: 2)
    )
    .contextMenu {
      SpaceMenuContent(store: store, space: space)
    }
  }

  private var profileFavorites: some View {
    let pages = FavoritePageIndex(store.session.favoritePages)
    let favorites = store.profileFavorites.map { favorite in
      let page = pages.page(for: favorite.id)
      return FavoriteTile(
        id: favorite.id, title: favorite.title, url: page?.tab.url ?? favorite.originalURL,
        image: store.favicon(for: favorite), pageID: page?.tab.id)
    }
    return ProfileFavoritesGrid(
      favorites: favorites,
      selectedID: store.session.selectedSpace.selectedFavoriteID,
      profileID: store.session.selectedSpace.profileID,
      dragSessionID: store.dragSessionID,
      onSelect: { _ = store.selectFavorite($0) },
      onReset: { _ = store.resetFavorite($0) },
      onRemove: { _ = store.removeFavorite($0) },
      onMoveBefore: { _ = store.moveFavorite($0, before: $1) },
      onTabDrop: { store.acceptFavoritesDrop($0, before: $1) },
      accessibilityOverrides: ProfileFavoritesAccessibilityOverrides(
        reduceMotion: sidebarReduceMotion,
        reduceTransparency: reduceTransparency
          || accessibilityOverrides.reduceTransparency == true),
      activeDrag: store.sidebarDrag,
      dropRefusal: store.favoritesDropRefusal(for: store.sidebarDrag),
      onBeginDrag: { store.beginSidebarDrag($0) })
  }

  private var recentDownloadsControls: some View {
    let profileID = store.session.selectedSpace.profileID
    let downloads = store.engine?.downloads
    let epoch = recentDownloads.epoch
    let isActive = store.isPrivate ? store.libraryDrawerSection == .spaces : recentDownloads.isOpen
    let controlLabel = store.isPrivate ? ShellL10n.string("Spaces") : ShellL10n.string("Downloads")
    return Button(action: toggleRecentDownloadsFromButton) {
      Image(systemName: store.isPrivate ? "square.grid.2x2" : "archivebox")
        .font(.system(size: 16))
        .foregroundStyle(Color.primary.opacity(isActive ? 0.9 : 0.55))
        .frame(width: 30, height: 30)
        .background(
          Color.primary.opacity(isActive ? 0.1 : 0),
          in: RoundedRectangle(cornerRadius: 8))
    }
    .contextMenu {
      if store.isPrivate {
        Button(ShellL10n.string("Spaces")) { _ = store.toggleLibraryDrawer() }
      } else {
        Button(ShellL10n.string("Bookmarks…")) { store.showLibrary(.bookmarks) }
        Button(ShellL10n.string("History…")) { store.showLibrary(.history) }
      }
    }
    .accessibilityLabel(controlLabel)
    .accessibilityHint(store.isPrivate ? "" : ShellL10n.string("Show recent downloads"))
    .help(controlLabel)
    .buttonStyle(.plain)
    .overlay(alignment: .bottomLeading) {
      Group {
        if recentDownloads.isOpen || previewRecentDownloads != nil,
          downloadsProfileIsCurrent(profileID),
          let items = previewRecentDownloads ?? downloads?.libraryItems(in: profileID)
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
              recentDownloads.dismiss(profileID: profileID, epoch: epoch)
            },
            backdrop: SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
          )
          .offset(y: -40)
          .transition(.opacity)
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
      recentDownloads.dismiss(profileID: profileID, epoch: epoch)
    }
    .onChange(of: profileID) { _, newProfileID in
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

  @ViewBuilder
  private func tabDropIndicator(_ intent: SidebarTabDropIntent) -> some View {
    switch intent {
    case .reorderBefore:
      Capsule().fill(Color.accentColor).frame(height: 2)
    case .reorderAfter:
      Capsule().fill(Color.accentColor).frame(height: 2)
        .frame(maxHeight: .infinity, alignment: .bottom)
    case .split, .addToSplit:
      Text(ShellL10n.string(intent == .addToSplit ? "Add to Split" : "Split with"))
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func beginFolderDraft(parentID: UUID?, section: SidebarSection = .pinned) {
    let route = FolderEditorRoute.create(spaceID: store.session.selectedSpaceID, parentID: parentID)
    guard route.matches(store.session) else { return }
    folderDraft = SidebarFolderDraft(route: route, section: section)
    folderNameIsFocused = true
  }

  private func commitFolderDraft() {
    guard let draft = folderDraft, draft.isValid(in: store.session),
      commitFolder(draft)
    else { return }
    folderDraft = nil
  }

  private func commitFolder(_ draft: SidebarFolderDraft) -> Bool {
    switch draft.route {
    case .create:
      return store.createFolder(
        name: draft.name, in: draft.spaceID, section: draft.section, parentID: draft.parentID)
        != nil
    case .edit(_, let folder):
      return store.renameFolder(folder, in: draft.spaceID, name: draft.name)
    }
  }

  private func scheduleFolderHover(_ tab: BrowserTab, in space: BrowserSpace) {
    guard !folderHoverDelay.isScheduled, folderDropReady == nil, tab.isPinned,
      !space.splits.contains(where: { $0.tabIDs.contains(tab.id) }),
      let drag = store.tabDrag, drag.tabID != tab.id
    else { return }
    // Measure the hold from the native event, even if other main-actor work delays the task.
    let deadline = ContinuousClock.now + .milliseconds(650)
    folderHoverDeadline = deadline
    folderHoverDelay.schedule(until: deadline) {
      folderHoverTab == tab.id && targetedTabIntent?.combinesTabs != false
    } activate: {
      folderDropReady = tab.id
    }
  }

  private func cancelFolderHover() {
    folderHoverDelay.cancel()
    folderDropReady = nil
    folderHoverTab = nil
    folderHoverSession = nil
    folderHoverDeadline = nil
  }

  private func folderDraftRow(depth: Int) -> some View {
    let cancelLabel = folderDraft?.cancelAccessibilityLabel ?? ShellL10n.string("Cancel")
    return HStack(spacing: 8) {
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
      .accessibilityLabel(PanelsL10n.string("Folder name"))
      .focused($folderNameIsFocused)
      .onSubmit(commitFolderDraft)
      .onExitCommand { folderDraft = nil }
      Button(role: .cancel) {
        folderDraft = nil
      } label: {
        Image(systemName: "xmark")
      }
      .font(.system(size: 9, weight: .medium))
      .help(cancelLabel)
      .accessibilityLabel(cancelLabel)
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

  private func toggleRecentDownloadsFromButton() {
    guard !store.isPrivate else {
      _ = store.toggleLibraryDrawer()
      return
    }
    guard store.libraryDrawerSection == nil, !store.commandIsOpen, store.sheet == nil else {
      return
    }
    recentDownloads.toggle(
      profileID: store.session.selectedSpace.profileID, epoch: recentDownloads.epoch)
  }

  private func closeRecentDownloadsPreview() {
    recentDownloads.dismiss(
      profileID: store.session.selectedSpace.profileID, epoch: recentDownloads.epoch)
  }

  @ViewBuilder
  private func tabRowContent(_ tab: BrowserTab, in space: BrowserSpace) -> some View {
    if let split = space.splits.first(where: { $0.tabIDs.first == tab.id }) {
      SidebarSplitRow(
        segments: split.tabIDs.compactMap { id in
          space.tabs.first { $0.id == id }.map {
            SidebarSplitRow.Segment(
              id: $0.id, title: $0.title,
              favicon: store.favicon(for: $0, profileID: space.profileID))
          }
        },
        focusedID: space.selectedTabID,
        isSelected: store.session.selectedPage.map { split.tabIDs.contains($0.tab.id) } ?? false,
        onSelect: { store.perform(.tab(space: space.id, tab: $0)) },
        onClose: { store.closeTab($0) },
        onDrag: { store.beginTabDrag($0, spaceID: space.id, fromSplitPane: true) },
        memberMenu: { id in
          AnyView(
            Group {
              Button(ShellL10n.string("Add to Favorites")) {
                _ = store.acceptFavoritesDrop(
                  .tab(
                    sessionID: store.dragSessionID, sourceSpaceID: space.id, tabID: id))
              }
              .disabled(!store.canAddTabToFavorites(id, in: space.id))
              Menu(ShellL10n.string("Move to Folder")) {
                ForEach(space.folders) { folder in
                  Button(folderLabel(folder.id, in: space)) {
                    _ = store.moveSplitMemberToFolder(id, in: space.id, folderID: folder.id)
                  }
                  .disabled(space.tabs.first { $0.id == id }?.folderID == folder.id)
                }
                if space.folders.isEmpty { ShellL10n.text("Create a folder first") }
              }
              Button(ShellL10n.string("Separate from Split")) { store.unsplitTab(id) }
              if let member = space.tabs.first(where: { $0.id == id }) {
                Button(
                  ShellL10n.string(
                    member.keepAlive ? "Stop keeping tab alive" : "Keep tab alive")
                ) { store.setKeepAlive(!member.keepAlive, for: id) }
              }
              Button(ShellL10n.string("Close tab")) { store.closeTab(id) }
            })
        },
        onStackDrag: {
          store.beginSidebarDrag(
            .split(sessionID: store.dragSessionID, sourceSpaceID: space.id, splitID: split.id))
        }
      )
    } else {
      SidebarTabRow(
        tabID: tab.id,
        title: tab.title,
        address: tab.url.absoluteString,
        favicon: store.favicon(for: tab, profileID: space.profileID),
        isPinned: tab.isPinned,
        isSelected: store.session.selectedPage?.tab.id == tab.id,
        closeIsVisible: hoveredTabID == tab.id,
        isSleeping: store.sleepingTabIDs.contains(tab.id),
        onSelect: { store.perform(.tab(space: space.id, tab: tab.id)) },
        onClose: { store.closeTab(tab.id) },
        onHoverChanged: { isHovered in
          hoveredTabID = hoveredTabID.updatingTarget(tab.id, isActive: isHovered)
        }
      )
      .sidebarPageMotion(id: tab.id, reduceMotion: sidebarReduceMotion)
      .draggable(store.beginTabDrag(tab.id, spaceID: space.id, fromSplitPane: false))
    }
  }

  /// Arc-style: add this tab to the open split on any side, or start a new split.
  @ViewBuilder
  private func splitMenu(for tab: BrowserTab, in space: BrowserSpace) -> some View {
    if let selected = store.selectedSplit, !selected.tabIDs.contains(tab.id),
      let focused = space.selectedTabID
    {
      Menu(ShellL10n.string("Add to Split View")) {
        ForEach(SplitEdge.allCases, id: \.self) { edge in
          Button(edge.menuTitle(isRightToLeft: layoutDirection == .rightToLeft)) {
            store.addToSplit(tab.id, beside: focused, edge: edge)
          }
        }
      }
      .disabled(store.selectedSplitIsFull)
    }
    let candidateRanges = SidebarSplitMenuCandidateRanges(tabs: space.tabs, excluding: tab.id)
    Menu(ShellL10n.string("Split View with…")) {
      ForEach(candidateRanges.before, id: \.self) { index in
        let candidate = space.tabs[index]
        Button(candidate.title) { store.splitTabs(tab.id, candidate.id) }
      }
      ForEach(candidateRanges.after, id: \.self) { index in
        let candidate = space.tabs[index]
        Button(candidate.title) { store.splitTabs(tab.id, candidate.id) }
      }
    }
    if space.splits.contains(where: { $0.tabIDs.contains(tab.id) }) {
      Button(ShellL10n.string("Separate from Split")) { store.unsplitTab(tab.id) }
    }
  }

  private func isSplitRowLeader(_ tab: BrowserTab, in space: BrowserSpace) -> Bool {
    guard let split = space.splits.first(where: { $0.tabIDs.contains(tab.id) }) else { return true }
    return split.tabIDs.first == tab.id
  }

  private func tabRow(_ tab: BrowserTab, index: SidebarTabIndex) -> some View {
    let space = store.session.selectedSpace
    let boundary = index.boundary(for: tab.id)
    return tabRowContent(tab, in: space)
      .dropDestination(for: SidebarTransfer.self) { items, point in
        guard items.count == 1, let item = items.first else { return false }
        let sourceID: UUID
        switch item {
        case .tab(_, _, let id): sourceID = id
        case .split(_, let source, let id):
          guard
            let leader = store.session.spaces.first(where: { $0.id == source })?
              .splits.first(where: { $0.id == id })?.tabIDs.first
          else {
            return false
          }
          sourceID = leader
        case .favorite, .url:
          return store.acceptSidebarDrop(
            item, into: space.id, before: tab.id, pinned: tab.isPinned, folderID: tab.folderID)
        default: return false
        }
        // A drop can reach the main actor before the hover task resumes after its deadline.
        let heldOverTab =
          folderHoverTab == tab.id
          && folderHoverDeadline.map { ContinuousClock.now >= $0 } == true
        if folderDropReady == tab.id || heldOverTab {
          defer { cancelFolderHover() }
          guard
            let folder = store.createFolderFromDrop(
              item, onto: tab.id, name: ShellL10n.string("Untitled"))
          else { return false }
          folderDraft = SidebarFolderDraft(
            route: .edit(spaceID: space.id, folderID: folder), section: .pinned)
          folderNameIsFocused = true
          return true
        }
        if let split = space.splits.first(where: { $0.tabIDs.contains(tab.id) }),
          split.tabIDs.contains(sourceID), sourceID != tab.id
        {
          return false
        }
        let joinsSplit = space.splits.contains(where: { $0.tabIDs.contains(tab.id) })
        let intent = SidebarTabDropIntent.at(point.y, joinsSplit: joinsSplit)
        if case .tab = item, sourceID != tab.id, intent.combinesTabs,
          space.tabs.contains(where: { $0.id == sourceID })
        {
          return store.dropTabIntoSidebarSplit(item, target: tab.id)
        }
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
        targetedTab = targetedTab.updatingTarget(tab.id, isActive: targeted)
        if !targeted { targetedTabIntent = nil }
      }
      .onDropSessionUpdated { drop in
        switch drop.phase {
        case .entering, .active:
          if folderHoverSession != drop.id || folderHoverTab != tab.id {
            cancelFolderHover()
            folderHoverSession = drop.id
            folderHoverTab = tab.id
          }
          let intent = SidebarTabDropIntent.at(
            drop.location.y,
            joinsSplit: space.splits.contains(where: { $0.tabIDs.contains(tab.id) }))
          targetedTabIntent = intent
          if intent.combinesTabs {
            scheduleFolderHover(tab, in: space)
          } else {
            cancelFolderHover()
          }
        case .exiting, .ended(.cancel), .ended(.forbidden), .dataTransferCompleted:
          if folderHoverSession == drop.id, folderHoverTab == tab.id { cancelFolderHover() }
        case .ended:
          // Transfer decoding can finish after isTargeted becomes false. Keep the offer
          // until the action consumes it, or this session completes/cancels.
          break
        @unknown default:
          cancelFolderHover()
        }
      }
      .overlay(alignment: .top) {
        if folderDropReady == tab.id {
          SidebarDropHint(
            title: ShellL10n.string("Create folder"), symbol: "folder.badge.plus", isTargeted: true)
        } else if targetedTab == tab.id {
          tabDropIndicator(targetedTabIntent ?? .reorderBefore)
        }
      }
      .animation(sidebarMotion, value: targetedTab)
      .animation(sidebarMotion, value: folderDropReady)
      .contextMenu {
        splitMenu(for: tab, in: space)
        Button(ShellL10n.string("Add to Favorites")) {
          addToFavorites(tabID: tab.id, spaceID: space.id, profileID: space.profileID)
        }
        .disabled(!store.canAddTabToFavorites(tab.id, in: space.id))
        Divider()
        Button(ShellL10n.string(tab.isPinned ? "Unpin tab" : "Pin tab")) { store.togglePin(tab.id) }
        Button(ShellL10n.string(tab.keepAlive ? "Stop keeping tab alive" : "Keep tab alive")) {
          store.setKeepAlive(!tab.keepAlive, for: tab.id)
        }
        Button(ShellL10n.string("Move up")) { shiftTab(tab, in: space, by: -1) }.disabled(
          boundary.isFirst)
        Button(ShellL10n.string("Move down")) { shiftTab(tab, in: space, by: 1) }.disabled(
          boundary.isLast)
        Menu(ShellL10n.string("Move to Folder")) {
          ForEach(space.folders) { folder in
            Button(folderLabel(folder.id, in: space)) {
              store.moveTab(tab.id, from: space.id, to: space.id, folderID: folder.id)
            }.disabled(tab.folderID == folder.id)
          }
          if tab.folderID != nil {
            Divider()
            Button(ShellL10n.string("Outside folders")) {
              store.moveTabOutsideFolder(tab.id, in: space.id)
            }
          }
          if space.folders.isEmpty { ShellL10n.text("Create a folder first") }
        }
        Menu(ShellL10n.string("Move to Space")) {
          let destinations = store.session.spaces.filter {
            $0.id != space.id && $0.profileID == space.profileID
          }
          if destinations.isEmpty { ShellL10n.text("No other spaces share this profile") }
          ForEach(destinations) { target in
            Button(target.name) { store.moveTab(tab.id, from: space.id, to: target.id) }
          }
        }
        Divider()
        Button(ShellL10n.string("Close tab")) { store.closeTab(tab.id) }
      }
  }

  private func tidyTabs(in space: BrowserSpace) {
    let tabs = space.tabs.filter { !$0.isPinned }
    guard !tabs.isEmpty, !tidyInProgress else { return }
    tidyInProgress = true
    Task { @MainActor in
      let groups = await SidebarTopicGrouping().groups(for: tabs)
      defer { tidyInProgress = false }
      guard store.session.selectedSpaceID == space.id,
        store.session.selectedSpace.tabs.filter({ !$0.isPinned }) == tabs
      else { return }
      store.applyTidyGroups(groups, in: space.id)
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
    pinned: Bool, isFooter: Bool = false, height: CGFloat = 12, hint: String? = nil
  ) -> some View {
    let space = store.session.selectedSpace.id
    let zone = sectionZone(pinned: pinned, isFooter: isFooter)
    let showsHint = hint != nil && store.tabDrag != nil
    return Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: sectionDropHeight(showsHint: showsHint, isFooter: isFooter, height: height))
      .overlay {
        if showsHint, let hint {
          SidebarDropHint(title: hint, symbol: "pin", isTargeted: targetedSection == zone)
        }
      }
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
        targetedSection = targetedSection.updatingTarget(zone, isActive: targeted)
      }
      .animation(sidebarReduceMotion ? nil : .easeOut(duration: 0.12), value: targetedSection)
      .animation(sidebarMotion, value: showsHint)
      .accessibilityHidden(true)
  }

  private func shiftTab(_ tab: BrowserTab, in space: BrowserSpace, by offset: Int) {
    let group = space.tabs.filter { $0.isPinned == tab.isPinned && $0.folderID == tab.folderID }
    guard let index = group.firstIndex(where: { $0.id == tab.id }),
      group.indices.contains(index + offset)
    else { return }
    let before = group.insertionAnchor(movingIndex: index, by: offset)
    store.moveTab(tab.id, from: space.id, to: space.id, before: before, folderID: tab.folderID)
  }

  private func sectionZone(pinned: Bool, isFooter: Bool) -> String {
    if isFooter { return "end" }
    return pinned ? "pinned" : "tabs"
  }

  private func sectionDropHeight(showsHint: Bool, isFooter: Bool, height: CGFloat) -> CGFloat {
    if showsHint { return 40 }
    return isFooter ? 32 : height
  }

  private func indentation(_ depth: Int) -> CGFloat { CGFloat(min(depth, 12)) * 10 }

  private func folderLabel(_ id: UUID, in space: BrowserSpace) -> String {
    space.folderPath(to: id).reversed().map(\.name).joined(separator: " / ")
  }

  private func folderRow(
    _ folder: BrowserFolder, depth: Int, siblingIndex: SidebarFolderSiblingIndex
  ) -> some View {
    let space = store.session.selectedSpace
    let active =
      space.folderPath(to: store.session.selectedPage?.tab.folderID).contains {
        $0.id == folder.id
      }
    let siblings = siblingIndex.siblings(of: folder)
    return Button {
      store.toggleFolder(folder.id, in: space.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: folder.isCollapsed ? "chevron.forward" : "chevron.down").font(
          .system(size: 9, weight: .semibold)
        )
        .frame(width: 10)
        Image(systemName: folder.isCollapsed ? "folder" : "folder.fill").font(.system(size: 12))
        VStack(alignment: .leading, spacing: 2) {
          Text(folder.name).font(.system(size: 13, weight: active ? .semibold : .regular))
            .lineLimit(1)
          if !space.tabs.contains(where: { $0.folderID == folder.id }),
            !space.folders.contains(where: { $0.parentID == folder.id })
          {
            ShellL10n.text("Drop tabs here").font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
        if folder.isCollapsed && active {
          Circle().fill(Color.accentColor).frame(width: 5, height: 5)
        }
      }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
    }
    .padding(.leading, indentation(depth))
    .sidebarPageMotion(id: folder.id, reduceMotion: sidebarReduceMotion)
    .accessibilityLabel(
      ShellL10n.format(
        "%@, %@",
        arguments: [
          .string(folder.name),
          .string(ShellL10n.string(folder.isCollapsed ? "collapsed" : "expanded")),
        ])
    )
    .help(folderLabel(folder.id, in: space))
    .draggable(
      store.beginSidebarDrag(
        .folder(
          sessionID: store.dragSessionID, sourceSpaceID: space.id, folderID: folder.id))
    )
    .dropDestination(for: SidebarTransfer.self) { items, _ in
      guard items.count == 1, let item = items.first else { return false }
      return store.acceptSidebarDrop(
        item, into: space.id, pinned: folder.isPinned, folderID: folder.id)
    } isTargeted: { targeted in
      targetedFolder = targetedFolder.updatingTarget(folder.id, isActive: targeted)
    }
    .background(
      targetedFolder == folder.id ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contextMenu {
      Button(ShellL10n.string("Edit folder…")) {
        store.showFolderEditor(.edit(spaceID: space.id, folderID: folder.id))
      }
      Button(ShellL10n.string("New Folder Inside")) {
        beginFolderDraft(parentID: folder.id, section: folder.isPinned ? .pinned : .today)
      }
      Divider()
      Button(ShellL10n.string("Move up")) { shiftFolder(folder, in: space, by: -1) }.disabled(
        siblings.first?.id == folder.id)
      Button(ShellL10n.string("Move down")) { shiftFolder(folder, in: space, by: 1) }.disabled(
        siblings.last?.id == folder.id)
      if folder.parentID != nil {
        Button(ShellL10n.string("Move out one level")) {
          let parent = space.folders.first { $0.id == folder.parentID }
          store.moveFolder(folder.id, from: space.id, to: space.id, parentID: parent?.parentID)
        }
      }
      Menu(ShellL10n.string("Move to Space")) {
        let destinations = store.session.spaces.filter {
          $0.id != space.id && $0.profileID == space.profileID
        }
        if destinations.isEmpty { ShellL10n.text("No other spaces share this profile") }
        ForEach(destinations) { target in
          Button(target.name) { store.moveFolder(folder.id, from: space.id, to: target.id) }
        }
      }
    }
  }

  private func shiftFolder(_ folder: BrowserFolder, in space: BrowserSpace, by offset: Int) {
    let siblings = SidebarFolderReorder.siblings(of: folder, in: space)
    guard let index = siblings.firstIndex(where: { $0.id == folder.id }),
      siblings.indices.contains(index + offset)
    else { return }
    let before = siblings.insertionAnchor(movingIndex: index, by: offset)
    store.moveFolder(
      folder.id, from: space.id, to: space.id, parentID: folder.parentID, before: before)
  }
}

@MainActor
final class SidebarFolderHoverDelay {
  private var task: Task<Void, Never>?
  private var activeID: UUID?

  var isScheduled: Bool { activeID != nil }

  func schedule(
    until deadline: ContinuousClock.Instant,
    isCurrent: @escaping @MainActor () -> Bool,
    activate: @escaping @MainActor () -> Void
  ) {
    guard activeID == nil else { return }
    let id = UUID()
    activeID = id
    task = Task { @MainActor [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch {}
      guard let self, self.activeID == id else { return }
      self.activeID = nil
      self.task = nil
      guard !Task.isCancelled, isCurrent() else { return }
      activate()
    }
  }

  func cancel() {
    activeID = nil
    task?.cancel()
    task = nil
  }

  func waitForCurrentTask() async {
    await task?.value
  }
}

enum SidebarFolderReorder {
  static func siblings(of folder: BrowserFolder, in space: BrowserSpace) -> [BrowserFolder] {
    space.folders.filter {
      $0.parentID == folder.parentID && $0.isPinned == folder.isPinned
    }
  }
}

/// What dropping a dragged tab onto a sidebar tab row does.
enum SidebarTabDropIntent: Equatable {
  case reorderBefore, reorderAfter, split, addToSplit

  /// The middle band of a row combines tabs; its top and bottom edges reorder.
  static func at(_ y: CGFloat, joinsSplit: Bool) -> Self {
    if y < 8 { return .reorderBefore }
    if y > 28 { return .reorderAfter }
    return joinsSplit ? .addToSplit : .split
  }

  var combinesTabs: Bool { self == .split || self == .addToSplit }
}
