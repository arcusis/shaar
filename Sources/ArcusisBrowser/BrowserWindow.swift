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
  @FocusState private var pageIsFocused: Bool

  var body: some View {
    ZStack(alignment: .top) {
      LinearGradient(
        colors: [
          store.session.selectedSpace.tint.color.opacity(0.50),
          Color(nsColor: .windowBackgroundColor),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
      )
      HStack(spacing: 0) {
        if store.sidebarIsVisible {
          BrowserSidebar(store: store)
            .frame(width: 240)
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
          CommandPanel(store: store)
            .frame(maxWidth: .infinity)
            .padding(.top, min(120, geometry.size.height * 0.12))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.commandIsOpen)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.sidebarIsVisible)
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
      case .downloads(let profile):
        if let engine = store.engine {
          DownloadsPanel(store: store, engine: engine, profileID: profile)
        }
      }
    }
    .onChange(of: store.commandIsOpen) { _, isOpen in
      if isOpen { store.engine?.extensionPanel = nil }
      if !isOpen && store.pageFind == nil {
        if let engine = store.engine, let id = store.session.selectedSpace.selectedTabID {
          engine.runtime.focusTabID(id.uuidString)
        } else {
          pageIsFocused = true
        }
      }
    }
    .onChange(of: store.pageFind?.id) { _, newValue in
      if newValue != nil { store.engine?.extensionPanel = nil }
    }
  }

  private var page: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button {
          store.sidebarIsVisible.toggle()
        } label: {
          Image(systemName: "sidebar.left")
        }
        .help("Toggle sidebar (Command-S)")
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
        Spacer()
        Button {
          store.showCommand()
        } label: {
          Label(
            store.session.selectedSpace.selectedTab?.url.host() ?? "Search or enter address",
            systemImage: "magnifyingglass"
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        Spacer()
        Button {
          store.bookmarkCurrentPage()
        } label: {
          Image(systemName: "star")
        }
        .disabled(!store.canBookmarkCurrentPage).help("Bookmark this page (Command-D)")
        .accessibilityLabel("Bookmark this page")
        Menu {
          Button("Bookmarks…") { store.showLibrary(.bookmarks) }
          Button("History…") { store.showLibrary(.history) }
        } label: {
          Image(systemName: "books.vertical")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Bookmarks and History")
        if let engine = store.engine {
          MediaCaptureIndicator(store: store, engine: engine)
          ExtensionToolbar(engine: engine, store: store)
          Button {
            store.showDownloads()
          } label: {
            Image(systemName: "arrow.down.circle")
          }
          .accessibilityLabel("Downloads")
          .help("Downloads (Shift-Command-J)")
        }
        Image(systemName: store.session.selectedSpace.symbol)
          .foregroundStyle(.secondary)
          .accessibilityLabel(store.session.selectedSpace.name)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      .frame(height: 44)
      Divider().opacity(0.4)
      if let find = store.pageFind {
        PageFindBar(store: store, state: find)
        Divider().opacity(0.4)
      }
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if let engine = store.engine, let id = store.session.selectedSpace.selectedTabID {
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
              .foregroundStyle(store.session.selectedSpace.tint.color)
            Text(store.session.selectedSpace.name)
              .font(.system(size: 30, weight: .medium, design: .rounded))
            Text(
              store.session.selectedSpace.selectedTab == nil
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
      .focused($pageIsFocused)
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

}
