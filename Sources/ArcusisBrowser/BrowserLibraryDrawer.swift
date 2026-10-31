// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum LibraryDrawerSection: String, CaseIterable, Identifiable {
  case media = "Media"
  case downloads = "Downloads"
  case spaces = "Spaces"

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
  @FocusState private var spacesSearchIsFocused: Bool

  private var section: LibraryDrawerSection { store.libraryDrawerSection ?? .downloads }

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        rail.frame(maxHeight: .infinity).frame(width: BrowserChromeLayout.libraryRailWidth)

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
    ZStack(alignment: .bottomLeading) {
      VStack(spacing: 8) {
        ForEach(LibraryDrawerSection.allCases) { item in sectionButton(item) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Button(action: closeAndFocusPage) {
        Image(systemName: "arrow.left")
          .font(.system(size: 16, weight: .medium))
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close Library")
      .accessibilityLabel("Close Library")
      .padding(8)
    }
    .padding(.horizontal, 8)
  }

  private func sectionButton(_ item: LibraryDrawerSection) -> some View {
    let isSelected = item == section
    return Button {
      _ = store.selectLibraryDrawerSection(item)
    } label: {
      VStack(spacing: 5) {
        Image(systemName: item.symbol).font(.system(size: 22, weight: .medium))
        Text(item.rawValue)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, minHeight: 72)
      .background(
        isSelected ? Color.primary.opacity(0.1) : Color.clear,
        in: RoundedRectangle(cornerRadius: 12)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
      let expectedProfiles = Dictionary(
        uniqueKeysWithValues: store.session.spaces.map { ($0.id, $0.profileID) })
      LibrarySpacesOverview(
        store: store,
        query: "",
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
