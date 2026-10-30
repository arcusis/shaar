import Foundation

public enum NavigationInput {
  public static func isWebURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
  }

  public static func destination(
    for input: String, searchEngine: BrowserSearchEngine = .google
  ) -> URL? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    if let url = URL(string: input), isWebURL(url) { return url }
    // Unsupported explicit schemes are never turned into executable navigation.
    if input.contains("://") || input.lowercased().hasPrefix("javascript:")
      || input.lowercased().hasPrefix("data:") || input.lowercased().hasPrefix("file:")
    {
      return nil
    }
    let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    if !input.contains(where: \.isWhitespace),
      host.contains(".") || host == "localhost" || host.hasPrefix("localhost:")
        || host.hasPrefix("["),
      let url = URL(string: "https://" + input), isWebURL(url)
    {
      return url
    }
    let endpoint: String
    switch searchEngine {
    case .google: endpoint = "https://www.google.com/search"
    case .duckDuckGo: endpoint = "https://duckduckgo.com/"
    case .bing: endpoint = "https://www.bing.com/search"
    }
    var search = URLComponents(string: endpoint)!
    search.queryItems = [URLQueryItem(name: "q", value: input)]
    return search.url
  }
}

public enum CommandAction: Hashable, Sendable {
  case open(URL)
  case tab(space: UUID, tab: UUID)
  case favorite(profile: UUID, id: UUID)
  case space(UUID)
  case folder(space: UUID, folder: UUID)
  case reopen(space: UUID, tab: UUID)
  case bookmark(profile: UUID, id: UUID)
  case history(profile: UUID, address: String)
  /// A host menu command, identified by its menu command name.
  case command(String)
}

public struct CommandResult: Identifiable, Equatable, Sendable {
  public var id: CommandAction { action }
  public let title: String
  public let subtitle: String
  public let symbol: String
  public let action: CommandAction

  public var isOpen: Bool {
    if case .open = action { return true }
    return false
  }
}

extension CommandResult {
  static func tab(_ tab: BrowserTab, space: UUID, subtitle: String) -> CommandResult {
    CommandResult(
      title: tab.title, subtitle: subtitle, symbol: "rectangle.on.rectangle",
      action: .tab(space: space, tab: tab.id))
  }

  static func favorite(_ favorite: BrowserFavorite, subtitle: String) -> CommandResult {
    CommandResult(
      title: favorite.title, subtitle: subtitle, symbol: "star.fill",
      action: .favorite(profile: favorite.profileID, id: favorite.id))
  }

  static func reopen(_ entry: ClosedBrowserTab, subtitle: String) -> CommandResult {
    CommandResult(
      title: entry.tab.title, subtitle: subtitle, symbol: "arrow.uturn.backward",
      action: .reopen(space: entry.spaceID, tab: entry.id))
  }

  static func bookmark(_ item: BrowserBookmark, subtitle: String) -> CommandResult {
    CommandResult(
      title: item.title, subtitle: subtitle, symbol: "star",
      action: .bookmark(profile: item.profileID, id: item.id))
  }

  static func history(_ entry: BrowserHistoryEntry, subtitle: String) -> CommandResult {
    CommandResult(
      title: entry.title, subtitle: subtitle, symbol: "clock",
      action: .history(profile: entry.profileID, address: entry.address))
  }

  static func command(_ command: LauncherCommand) -> CommandResult {
    CommandResult(
      title: command.title, subtitle: command.detail, symbol: command.symbol,
      action: .command(command.id))
  }
}

public enum CommandSearch {
  static let resultLimit = 10

  public static func results(
    for query: String, in session: BrowserSession,
    bookmarks: [BrowserBookmark] = [], history: [BrowserHistoryEntry] = [],
    searchEngine: BrowserSearchEngine = .google
  ) -> [CommandResult] {
    results(
      for: query, in: session, bookmarks: bookmarks, history: history,
      searchEngine: searchEngine, limit: resultLimit)
  }

  /// `limit` counts every row, including the final Open row when input can navigate.
  static func results(
    for query: String, in session: BrowserSession,
    bookmarks: [BrowserBookmark], history: [BrowserHistoryEntry],
    searchEngine: BrowserSearchEngine, limit: Int
  ) -> [CommandResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let openURL = NavigationInput.destination(for: query, searchEngine: searchEngine)
    let candidateLimit = openURL == nil ? limit : limit - 1
    var results: [CommandResult] = []
    func append(_ result: CommandResult) -> Bool {
      results.append(result)
      return results.count >= candidateLimit
    }

    let orderedSpaces = session.spaces.sorted {
      $0.id == session.selectedSpaceID && $1.id != session.selectedSpaceID
    }
    let profileID = session.selectedSpace.profileID
    let profileName = session.profiles.first { $0.id == profileID }?.name ?? ""
    let hasScopedFavorites = session.favorites.contains { $0.profileID == profileID }
    let favoritePages =
      hasScopedFavorites
      ? Dictionary(uniqueKeysWithValues: session.favoritePages.map { ($0.favoriteID, $0) }) : [:]
    for favorite in session.favorites where favorite.profileID == profileID {
      let page = favoritePages[favorite.id]
      let searchable = [
        favorite.title, favorite.originalURL.absoluteString,
        page?.tab.title ?? "", page?.tab.url.absoluteString ?? "",
      ].joined(separator: " ")
      guard query.isEmpty || searchable.localizedCaseInsensitiveContains(query) else { continue }
      let currentURL = page?.tab.url ?? favorite.originalURL
      if append(
        .favorite(
          favorite, subtitle: "Favorite · \(profileName) profile · \(currentURL.host() ?? "")"))
      {
        break
      }
    }
    search: for space in orderedSpaces where results.count < candidateLimit {
      let foldersByID = Dictionary(
        space.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var folderPaths: [UUID?: String] = [nil: ""]
      func folderPathString(to id: UUID?) -> String {
        if let cached = folderPaths[id] { return cached }
        var path: [BrowserFolder] = []
        var next = id
        var visited: Set<UUID> = []
        while let current = next, let folder = foldersByID[current],
          visited.insert(current).inserted
        {
          path.append(folder)
          next = folder.parentID
        }
        let value = path.reversed().map(\.name).joined(separator: " / ")
        folderPaths[id] = value
        return value
      }
      func appendTabResult(_ tab: BrowserTab) -> Bool {
        let path = folderPathString(to: tab.folderID)
        guard
          query.isEmpty
            || "\(tab.title) \(tab.url.absoluteString) \(path)".localizedCaseInsensitiveContains(
              query)
        else { return false }
        let context = path.isEmpty ? space.name : "\(space.name) · \(path)"
        if append(.tab(tab, space: space.id, subtitle: "\(context) · \(tab.url.host() ?? "")")) {
          return true
        }
        return false
      }
      for tab in space.orderedTabs {
        if appendTabResult(tab) { break search }
      }
      for folder in space.folders {
        let path = folderPathString(to: folder.id)
        if query.isEmpty || path.localizedCaseInsensitiveContains(query) {
          if append(
            CommandResult(
              title: folder.name, subtitle: "\(space.name) · \(path)",
              symbol: "folder", action: .folder(space: space.id, folder: folder.id)))
          {
            break search
          }
        }
      }
      if query.isEmpty || space.name.localizedCaseInsensitiveContains(query) {
        let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
        if append(
          CommandResult(
            title: space.name, subtitle: "Switch space · \(profile) profile",
            symbol: space.symbol, action: .space(space.id)
          ))
        {
          break search
        }
      }
      if space.id == session.selectedSpaceID {
        for entry in session.recentlyClosedTabs(in: space.id)
        where query.isEmpty
          || "Reopen closed tab \(entry.tab.title) \(entry.tab.url.absoluteString)"
            .localizedCaseInsensitiveContains(query)
        {
          let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
          if append(
            .reopen(entry, subtitle: "Reopen closed tab · \(space.name) · \(profile) profile"))
          {
            break search
          }
        }
        let profile = space.profileID
        let profileName = session.profiles.first { $0.id == profile }?.name ?? ""
        var bookmarked: Set<String> = []
        for item in bookmarks where item.profileID == profile && item.destination != nil {
          guard
            query.isEmpty
              || "\(item.title) \(item.address ?? "") \(item.path)"
                .localizedCaseInsensitiveContains(query)
          else { continue }
          bookmarked.insert(item.address!)
          if append(.bookmark(item, subtitle: "Bookmark · \(profileName) profile · \(item.path)")) {
            break search
          }
        }
        for entry in history
        where entry.profileID == profile && entry.destination != nil
          && !bookmarked.contains(entry.address)
        {
          guard
            query.isEmpty
              || "\(entry.title) \(entry.address)".localizedCaseInsensitiveContains(query)
          else { continue }
          if append(
            .history(
              entry,
              subtitle:
                "History · \(profileName) profile · \(entry.lastVisit.formatted(date: .abbreviated, time: .omitted))"
            ))
          {
            break search
          }
        }
      }
    }
    if let openURL {
      results.append(
        CommandResult(
          title: query, subtitle: "Open in \(session.selectedSpace.name)",
          symbol: "arrow.up.right", action: .open(openURL)
        ))
    }
    return results
  }

}
