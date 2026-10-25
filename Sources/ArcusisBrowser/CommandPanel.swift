import AppKit
import BrowserCore
import SwiftUI

struct CommandPanel: View {
  @Bindable var store: BrowserStore
  let resultsHeight: CGFloat
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 21, weight: .light))
          .foregroundStyle(.secondary)
        TextField("Search or enter address", text: $store.commandQuery)
          .textFieldStyle(.plain)
          .font(.system(size: 21))
          .focused($searchIsFocused)
          .onSubmit { store.acceptCommand() }
          .accessibilityIdentifier("command-search")
        Text("esc")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
      }
      .padding(22)
      Divider()
      let results = store.results
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 3) {
            if results.isEmpty {
              Text("No matching tabs or spaces")
                .foregroundStyle(.secondary)
                .padding(20)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
              let isSelected = index == store.commandSelection
              Button {
                store.perform(result.action)
              } label: {
                HStack(spacing: 12) {
                  if let favicon = favicon(for: result.action) {
                    Image(nsImage: favicon)
                      .resizable()
                      .scaledToFit()
                      .frame(width: 18, height: 18)
                      .frame(width: 26)
                  } else {
                    Image(systemName: result.symbol)
                      .font(.system(size: 15))
                      .foregroundStyle(.secondary)
                      .frame(width: 26)
                  }
                  VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                      .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                      .lineLimit(1)
                    Text(subtitle(for: result))
                      .font(.system(size: 11))
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  Spacer()
                  Text(actionLabel(for: result))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
                  if isSelected {
                    Image(systemName: "return")
                      .font(.system(size: 11, weight: .semibold))
                      .foregroundStyle(Color.accentColor)
                  }
                }
                .padding(12)
                .contentShape(Rectangle())
                .background(
                  isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                  if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                      .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1)
                  }
                }
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(index == store.commandSelection ? .isSelected : [])
              .id(result.id)
            }
          }
          .padding(8)
        }
        .frame(height: resultsHeight)
        .onChange(of: store.commandSelection) { _, index in
          guard results.indices.contains(index) else { return }
          proxy.scrollTo(results[index].id)
        }
      }
      Divider()
      HStack {
        Label(store.profileName, systemImage: "person.crop.circle")
        Spacer()
        Text("↑↓ select    ↩ open")
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
    }
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
    .clipShape(RoundedRectangle(cornerRadius: 17))
    .overlay {
      RoundedRectangle(cornerRadius: 17)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
    .onAppear { searchIsFocused = true }
    .onChange(of: store.commandQuery) { _, _ in store.commandSelection = 0 }
    .onKeyPress(.upArrow) {
      store.moveCommandSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      store.moveCommandSelection(by: 1)
      return .handled
    }
    .onExitCommand { store.dismissCommand() }
    .accessibilityLabel("Search tabs, spaces, or the web")
  }

  private func favicon(for action: CommandAction) -> NSImage? {
    let tabID: UUID
    switch action {
    case .tab(_, let id):
      guard store.session.spaces.contains(where: { $0.tabs.contains(where: { $0.id == id }) })
      else { return nil }
      tabID = id
    case .favorite(let profileID, let favoriteID):
      guard
        store.session.favorites.contains(where: { $0.id == favoriteID && $0.profileID == profileID }
        ),
        let page = store.session.favoritePages.first(where: { $0.favoriteID == favoriteID }),
        store.session.profileID(forTabID: page.tab.id) == profileID
      else { return nil }
      tabID = page.tab.id
    default:
      return nil
    }
    return store.engine?.favicons[tabID]
  }

  private func subtitle(for result: CommandResult) -> String {
    guard case .tab(let spaceID, _) = result.action,
      let space = store.session.spaces.first(where: { $0.id == spaceID }),
      space.profileID != store.session.selectedSpace.profileID,
      let profile = store.session.profiles.first(where: { $0.id == space.profileID })
    else { return result.subtitle }
    return "\(result.subtitle) · \(profile.name) profile"
  }

  private func actionLabel(for result: CommandResult) -> String {
    switch result.action {
    case .tab: "Switch to Tab"
    case .favorite: "Open Favorite"
    case .space: "Switch Space"
    case .folder: "Open Folder"
    case .reopen: "Reopen Tab"
    case .bookmark: "Open Bookmark"
    case .history: "Open History"
    case .open(let url): isWebSearch(url) ? "Search Web" : "Open"
    }
  }

  private func isWebSearch(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "q" && !($0.value ?? "").isEmpty })
        == true
    else { return false }
    return switch (url.host(), components.path) {
    case ("www.google.com", "/search"), ("www.bing.com", "/search"),
      ("duckduckgo.com", "/"):
      true
    default:
      false
    }
  }
}
