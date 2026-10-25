import BrowserCore
import SwiftUI

enum LibraryDrawerSection: String, CaseIterable, Identifiable {
  case spaces = "Spaces"
  case downloads = "Downloads"
  case media = "Media"

  var id: Self { self }

  var symbol: String {
    switch self {
    case .spaces: "square.grid.2x2"
    case .downloads: "arrow.down.circle"
    case .media: "photo.on.rectangle.angled"
    }
  }
}

struct BrowserLibraryDrawer: View {
  @Bindable var store: BrowserStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var spacesQuery = ""
  @FocusState private var spacesSearchIsFocused: Bool

  private var section: LibraryDrawerSection { store.libraryDrawerSection ?? .spaces }

  var body: some View {
    GeometryReader { geometry in
      let railWidth = min(max(geometry.size.width * 0.18, 82), 92)
      HStack(spacing: 0) {
        rail.frame(maxHeight: .infinity, alignment: .topLeading).frame(width: railWidth)

        Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1)

        Group {
          switch section {
          case .spaces:
            spacesContent
          case .downloads:
            if let profileID = store.libraryDrawerProfileID {
              LibraryDownloadsView(store: store, profileID: profileID, mediaOnly: false)
            } else {
              ContentUnavailableView("Profile changed", systemImage: "person.crop.circle")
            }
          case .media:
            if let profileID = store.libraryDrawerProfileID {
              LibraryDownloadsView(store: store, profileID: profileID, mediaOnly: true)
            } else {
              ContentUnavailableView("Profile changed", systemImage: "person.crop.circle")
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 15))
      .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.1)))
      .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.16), radius: 20, y: 8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Library")
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.libraryDrawerSection)
    .onAppear { if section == .spaces { spacesSearchIsFocused = true } }
    .onChange(of: store.libraryDrawerSection) { _, value in
      if case .spaces? = value { spacesSearchIsFocused = true }
    }
  }

  private var rail: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 2) {
        if section != .spaces { backButton }
        Spacer(minLength: 0)
        closeButton
      }
      .buttonStyle(.plain)
      .padding(.bottom, 8)
      ForEach(LibraryDrawerSection.allCases) { item in sectionButton(item) }
      Spacer(minLength: 0)
    }
    .padding(8)
  }

  private var backButton: some View {
    Button {
      _ = store.selectLibraryDrawerSection(.spaces)
    } label: {
      VStack(spacing: 2) {
        Image(systemName: "chevron.left")
        Text("Back").font(.system(size: 9))
      }
      .frame(width: 30, height: 34)
    }
    .help("Back to Spaces")
    .accessibilityLabel("Back to Spaces")
  }

  private var closeButton: some View {
    Button(action: closeAndFocusPage) {
      VStack(spacing: 2) {
        Image(systemName: "xmark")
        Text("Close").font(.system(size: 9))
      }
      .frame(width: 34, height: 34)
    }
    .help("Close Library")
    .accessibilityLabel("Close Library")
  }

  private func sectionButton(_ item: LibraryDrawerSection) -> some View {
    let isSelected = item == section
    let labelWeight: Font.Weight = isSelected ? .semibold : .regular
    return Button {
      _ = store.selectLibraryDrawerSection(item)
    } label: {
      VStack(spacing: 5) {
        Image(systemName: item.symbol).font(.system(size: 17, weight: .medium))
        Text(item.rawValue)
          .font(.system(size: 10, weight: labelWeight))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(
        isSelected ? Color.primary.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func closeAndFocusPage() {
    store.closeLibraryDrawer()
    guard store.sheet == nil, !store.commandIsOpen, store.pageFind == nil,
      let engine = store.engine,
      engine.runtime.window(forID: engine.windowID)?.isKeyWindow == true,
      let id = store.session.selectedPage?.tab.id
    else { return }
    engine.runtime.focusTabID(id.uuidString)
  }

  private var spacesContent: some View {
    VStack(spacing: 0) {
      TextField("Search Spaces", text: $spacesQuery)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search Spaces")
        .focused($spacesSearchIsFocused)
        .padding(.horizontal, 14)
        .padding(.top, 14)
      let expectedProfiles = Dictionary(
        uniqueKeysWithValues: store.session.spaces.map { ($0.id, $0.profileID) })
      LibrarySpacesOverview(
        store: store,
        query: spacesQuery,
        onSelectSpace: { id in
          guard let profile = expectedProfiles[id] else { return }
          _ = store.selectLibrarySpace(id, expectedProfileID: profile)
        },
        onSelectTab: { spaceID, tabID in
          guard let profile = expectedProfiles[spaceID] else { return }
          _ = store.selectLibraryTab(tabID, in: spaceID, expectedProfileID: profile)
        },
        onEditSpace: { id in
          guard let profile = expectedProfiles[id] else { return }
          _ = store.editLibrarySpace(id, expectedProfileID: profile)
        },
        onCreateSpace: { _ = store.createLibrarySpace() }
      )
    }
  }
}
