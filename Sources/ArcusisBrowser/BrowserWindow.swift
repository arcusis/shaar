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

  var body: some View {
    ZStack(alignment: .top) {
      SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme)
      HStack(spacing: 0) {
        if store.sidebarIsVisible {
          BrowserSidebar(store: store)
            .frame(width: BrowserChromeLayout.sidebarWidth)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        page
          .padding(.top, 10)
          .padding(.trailing, 10)
          .padding(.bottom, 10)
          .padding(.leading, store.sidebarIsVisible ? 0 : 10)
      }
      if store.commandIsOpen {
        Color.black.opacity(0.16)
          .ignoresSafeArea()
          .onTapGesture { store.dismissCommand() }
        GeometryReader { geometry in
          let contentLeft = store.sidebarIsVisible ? BrowserChromeLayout.sidebarWidth : 10
          let contentTop: CGFloat = store.pageFind == nil ? 45 : 95
          let initialContentFrame = CGRect(
            x: contentLeft, y: contentTop,
            width: max(0, geometry.size.width - contentLeft - 10),
            height: max(0, geometry.size.height - contentTop - 10))
          let frame = BrowserChromeLayout.commandPanelFrame(
            in: webContentFrame.isEmpty ? initialContentFrame : webContentFrame,
            resultCount: store.results.count
          )
          CommandPanel(
            store: store,
            resultsHeight: BrowserChromeLayout.commandResultsHeight(
              resultCount: store.results.count,
              availableHeight: frame.height
            )
          )
          .frame(width: frame.width)
          .fixedSize(horizontal: false, vertical: true)
          .position(x: frame.midX, y: frame.midY)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }
      if let coordinator = store.engine?.passwordFill,
        BrowserEngine.passwordFillInputAvailable(in: store),
        coordinator.showingPicker || coordinator.message != nil
      {
        PasswordFillOverlay(coordinator: coordinator)
          .zIndex(3)
      }
      if store.libraryDrawerSection != nil, store.canUseLibraryDrawer {
        GeometryReader { geometry in
          let leading: CGFloat = 10
          let availableWidth = max(0, geometry.size.width - leading - 20)
          let isSpaces = store.libraryDrawerSection == .spaces
          let width = isSpaces ? availableWidth : min(480, availableWidth)
          let height = max(0, geometry.size.height - 32)
          ZStack(alignment: .bottomLeading) {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { dismissLibraryDrawerAndFocusPage() }
            BrowserLibraryDrawer(store: store)
              .frame(width: width, height: height)
              .padding(.leading, leading)
              .padding(.bottom, 20)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(store.libraryDrawerSection != nil && store.canUseLibraryDrawer)
        .transition(.opacity)
        .zIndex(2)
      }
    }
    .overlay { TabSwitcherPanel(store: store) }
    .coordinateSpace(name: "browser-window")
    .onPreferenceChange(WebContentFramePreferenceKey.self) { webContentFrame = $0 }
    .frame(minWidth: 760, minHeight: 520)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.commandIsOpen)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.sidebarIsVisible)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: SpaceChromeTint(space: store.session.selectedSpace)
    )
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
      case .websiteMedia(let request): WebsiteMediaConsent(store: store, request: request)
      case .externalApp(let request): ExternalAppConsent(store: store, request: request)
      case .downloads(let profile):
        if let engine = store.engine {
          DownloadsPanel(store: store, engine: engine, profileID: profile)
        }
      }
    }
    .onChange(of: store.commandIsOpen) { _, isOpen in
      if isOpen {
        store.engine?.passwordFill?.cancel()
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
    .onChange(of: store.sheet?.id) { _, newValue in
      if newValue != nil { store.engine?.passwordFill?.cancel() }
    }
    .onChange(of: store.pageFind?.id) { _, newValue in
      if newValue != nil {
        store.engine?.passwordFill?.cancel()
        store.engine?.extensionPanel = nil
      }
    }
    .onChange(of: store.libraryDrawerSection) { _, newValue in
      if newValue != nil { store.engine?.passwordFill?.cancel() }
    }
    .onExitCommand {
      if let fill = store.engine?.passwordFill, fill.showingPicker || fill.message != nil {
        fill.cancel()
      } else if store.libraryDrawerSection != nil {
        dismissLibraryDrawerAndFocusPage()
      }
    }
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
          if let failure = store.rendererFailures[id] {
            FailedPageView(store: store, failure: failure)
          } else if engine.pages[id] != nil {
            ChromiumPage(engine: engine, tabID: id)
          } else {
            ProgressView("Loading profile…")
          }
        } else {
          VStack(spacing: 18) {
            Image(systemName: store.session.selectedSpace.symbol)
              .font(.system(size: 32, weight: .light))
              .foregroundStyle(.secondary)
            Text(store.session.selectedSpace.name)
              .font(.system(size: 30, weight: .medium, design: .rounded))
            Text(
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
                Text("Search or enter address")
                Spacer(minLength: 40)
                Text("⌘T").foregroundStyle(.tertiary)
              }
              .font(.system(size: 14))
              .padding(16)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 420)
            Text("\(store.profileName) profile")
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
    .clipShape(RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.black.opacity(0.07)))
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
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

private struct WebContentFramePreferenceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}
