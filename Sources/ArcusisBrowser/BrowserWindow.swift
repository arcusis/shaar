// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

extension SpaceTint {
  var color: Color {
    switch self {
    case .lavender: Color(red: 0.66, green: 0.60, blue: 0.83)
    case .ocean: Color(red: 0.42, green: 0.67, blue: 0.79)
    case .rose: Color(red: 0.81, green: 0.53, blue: 0.61)
    case .forest: Color(red: 0.44, green: 0.65, blue: 0.52)
    }
  }
}

struct BrowserWindow: View {
  @Bindable var store: BrowserStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var pageIsFocused: Bool
  @State private var webContentFrame: CGRect = .zero
  @State private var sidebarVisibility: SidebarVisibility = .pinned
  @State private var isFullScreen = false

  var body: some View {
    ZStack(alignment: .top) {
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
      GeometryReader { geometry in
        let libraryIsOpen = store.libraryDrawerSection != nil && store.canUseLibraryDrawer
        let leadingWidth =
          libraryIsOpen
          ? BrowserChromeLayout.libraryWidth(
            windowWidth: geometry.size.width, spaces: store.libraryDrawerSection == .spaces)
          : (store.sidebarIsVisible ? BrowserChromeLayout.sidebarWidth : 0)
        let pageWidth = BrowserChromeLayout.pageWidth(
          windowWidth: geometry.size.width, leadingWidth: leadingWidth)
        HStack(spacing: 0) {
          ZStack(alignment: .leading) {
            if libraryIsOpen {
              BrowserLibraryDrawer(store: store)
                .transition(.opacity)
            }
          }
          .animation(
            reduceMotion ? .easeOut(duration: 0.12) : nil, value: store.libraryDrawerSection
          )
          .frame(width: leadingWidth)
          page
            .padding(BrowserChromeLayout.pageCardInset)
            .frame(width: pageWidth)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: store.libraryDrawerSection)
      }
      sidebarLayer
      if store.commandIsOpen {
        Color.black.opacity(0.16)
          .ignoresSafeArea()
          .onTapGesture { store.dismissCommand() }
          .transition(.opacity)
      }

    }
    .overlay { commandPanelLayer }
    .overlay { TabSwitcherPanel(store: store) }
    .background { WindowFullScreenObserver(isFullScreen: $isFullScreen) }
    .environment(\.browserWindowIsFullScreen, isFullScreen)
    .coordinateSpace(name: "browser-window")
    .onPreferenceChange(WebContentFramePreferenceKey.self) { webContentFrame = $0 }
    .frame(minWidth: 760, minHeight: 520)
    .animation(
      reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.15), value: store.commandIsOpen
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.sidebarIsVisible)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: SpaceChromeTint(space: store.session.selectedSpace)
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: sidebarVisibility)
    .onAppear { sidebarVisibility.setPinned(store.sidebarIsVisible) }
    .onChange(of: store.sidebarIsVisible) { _, pinned in
      sidebarVisibility.setPinned(pinned)
    }
    .modifier(SpaceMenuDialogs(store: store))
    .sheet(
      item: store.engine?.presentsNativePanels == false ? .constant(nil) : $store.sheet,
      onDismiss: { store.sheetDidDismiss() }
    ) { sheet in
      switch sheet {
      case .space(let route): SpaceEditor(store: store, route: route)
      case .folder(let route): FolderEditor(store: store, route: route)
      case .recentlyClosed(let space): RecentlyClosedPanel(store: store, spaceID: space)
      case .library(let profile, let section):
        LibraryPanel(store: store, profileID: profile, section: section)
      case .bookmarkEditor(let route): BookmarkEditor(store: store, route: route)
      case .extensionInstall(let request): ExtensionConsent(store: store, request: request)
      case .websitePermission(let request): WebsitePermissionConsent(store: store, request: request)
      case .externalApp(let request): ExternalAppConsent(store: store, request: request)
      case .downloads(let profile):
        if let engine = store.engine {
          DownloadsPanel(store: store, engine: engine, profileID: profile)
        }
      }
    }
    .onChange(of: store.commandIsOpen) { _, isOpen in
      if isOpen {
        store.engine?.extensionPanel = nil
      }
      if !isOpen && store.pageFind == nil {
        if let engine = store.engine, let id = store.session.selectedPage?.tab.id {
          DispatchQueue.main.async { engine.focusPage(id) }
        } else {
          pageIsFocused = true
        }
      }
    }
    .onChange(of: store.pageFind?.id) { _, newValue in
      if newValue != nil {
        store.engine?.extensionPanel = nil
      }
    }
    .onExitCommand {
      if store.libraryDrawerSection != nil {
        dismissLibraryDrawerAndFocusPage()
      }
    }
    .shellLocalization()
  }

  private var page: some View {
    VStack(spacing: 0) {
      BrowserChromeSurface(store: store, engine: store.engine)
      Divider().opacity(0.4)
      if let find = store.pageFind {
        PageFindBar(store: store, state: find)
        Divider().opacity(0.4)
      }
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if let engine = store.engine, let id = store.session.selectedPage?.tab.id {
          if let split = store.selectedSplit {
            BrowserSplitPageView(store: store, engine: engine, split: split)
          } else if let failure = store.rendererFailures[id] {
            FailedPageView(store: store, failure: failure)
          } else if engine.pages[id] != nil {
            ChromiumPage(engine: engine, tabID: id)
              .overlay { SplitDropZone(store: store, targetID: id) }
          } else {
            ProgressView(ShellL10n.string("Loading profile…"))
          }
        } else {
          VStack(spacing: 18) {
            Image(systemName: store.session.selectedSpace.symbol)
              .font(.system(size: 32, weight: .light))
              .foregroundStyle(.secondary)
            Text(store.session.selectedSpace.name)
              .font(.system(size: 30, weight: .medium, design: .rounded))
            ShellL10n.text(
              store.session.selectedPage == nil
                ? "A little room for your next idea."
                : "Browsing is not available in this development preview."
            )
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            Button {
              store.showCommand()
            } label: {
              HStack {
                Image(systemName: "magnifyingglass")
                ShellL10n.text("Search or enter address")
                Spacer(minLength: 40)
                ShellL10n.text("⌘T").foregroundStyle(.tertiary)
              }
              .font(.system(size: 14))
              .padding(16)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 420)
            Text(ShellL10n.format("%@ profile", arguments: [.string(store.profileName)]))
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
          .padding(32)
        }
      }
      .focusable()
      .focusEffectDisabled()
      .focused($pageIsFocused)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: WebContentFramePreferenceKey.self,
            value: geometry.frame(in: .named("browser-window"))
          )
        }
      }
      if let notice = store.storageNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.orange)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let notice = store.engine?.notice {
        Text(notice).font(.caption).foregroundStyle(.orange).padding(12)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.pageCardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: BrowserChromeLayout.pageCardRadius)
        .strokeBorder(.black.opacity(0.07))
    )
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
  }

  /// An overlay, so it never affects window layout, that takes no clicks while the launcher is
  /// closed. The panel is inserted inside the reader so its scale transition anchors on the panel.
  private var sidebarLayer: AnyView {
    AnyView(
      Group {
        if store.libraryDrawerSection == nil {
          if !store.sidebarIsVisible {
            HStack(spacing: 0) {
              Color.clear
                .contentShape(Rectangle())
                .frame(width: 6)
                .onHover { inside in
                  if inside { sidebarVisibility.pointerEnteredEdge() }
                }
              Spacer(minLength: 0)
            }
          }
          HStack(spacing: 0) {
            BrowserSidebar(store: store)
              .frame(width: BrowserChromeLayout.sidebarWidth)
              .modifier(SidebarHiddenOffset(isHidden: sidebarVisibility == .hidden))
              .allowsHitTesting(sidebarVisibility != .hidden)
              .accessibilityHidden(sidebarVisibility == .hidden)
              .onHover { inside in
                if !inside { sidebarVisibility.pointerLeftSidebar() }
              }
            Spacer(minLength: 0)
          }
          if store.sidebarIsVisible {
            TitlebarSidebarToggle(store: store)
          }
        }
      }
    )
  }

  private var commandPanelLayer: some View {
    GeometryReader { geometry in
      if store.commandIsOpen {
        commandPanel(in: geometry.size)
      }
    }
    .allowsHitTesting(store.commandIsOpen)
    .accessibilityHidden(!store.commandIsOpen)
  }

  private func commandPanel(in size: CGSize) -> some View {
    let initialContentFrame = BrowserChromeLayout.initialWebContentFrame(
      size: size, sidebarVisible: store.sidebarIsVisible,
      isRightToLeft: BrowserLanguage.currentLaunchLanguage.isRightToLeft,
      findBarVisible: store.pageFind != nil)
    let sections = store.commandSections
    let frame = BrowserChromeLayout.commandPanelFrame(
      in: webContentFrame.isEmpty ? initialContentFrame : webContentFrame,
      resultCount: sections.results.count, headerCount: sections.headerCount
    )
    let resultsHeight = BrowserChromeLayout.commandResultsHeight(
      resultCount: sections.results.count, headerCount: sections.headerCount,
      availableHeight: frame.height
    )
    // SwiftUI positions from the leading edge; the measured page frame uses physical x.
    let centerX =
      BrowserLanguage.currentLaunchLanguage.isRightToLeft
      ? size.width - frame.midX : frame.midX
    let anchor = UnitPoint(
      x: centerX / max(size.width, 1), y: frame.midY / max(size.height, 1))
    return CommandPanel(store: store, resultsHeight: resultsHeight)
      .frame(width: frame.width)
      .fixedSize(horizontal: false, vertical: true)
      .position(x: centerX, y: frame.midY)
      .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.1), value: resultsHeight)
      .transition(.scale(scale: 0.94, anchor: anchor).combined(with: .opacity))
  }

  private func dismissLibraryDrawerAndFocusPage() {
    store.closeLibraryDrawer()
    if let engine = store.engine, let id = store.session.selectedPage?.tab.id {
      engine.runtime.focusTabID(id.uuidString)
    } else {
      pageIsFocused = true
    }
  }

}

private struct SidebarHiddenOffset: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content.offset(
      x: isHidden
        ? BrowserChromeLayout.hiddenSidebarOffset : 0)
  }
}

private struct WebContentFramePreferenceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}
