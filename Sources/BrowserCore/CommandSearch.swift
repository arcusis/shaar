// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum NavigationInput {
  public static func isWebURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
  }

  /// The input as a web address (`https://…`, `example.com`, `localhost:3000`), or nil when
  /// it is text to search for or uses an unsupported scheme.
  public static func address(for input: String) -> URL? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    if let url = URL(string: input), isWebURL(url) { return url }
    if hasUnsupportedScheme(input) { return nil }
    let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    guard !input.contains(where: \.isWhitespace),
      host.contains(".") || host == "localhost" || host.hasPrefix("localhost:")
        || host.hasPrefix("["),
      let url = URL(string: "https://" + input), isWebURL(url)
    else { return nil }
    return url
  }

  public static func destination(
    for input: String, searchEngine: BrowserSearchEngine = .google
  ) -> URL? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    if let url = address(for: input) { return url }
    // Unsupported explicit schemes are never turned into executable navigation.
    if hasUnsupportedScheme(input) { return nil }
    let endpoint = searchEngine.searchEndpoint
    var search = URLComponents(string: endpoint.url)
    search?.queryItems = [URLQueryItem(name: endpoint.queryName, value: input)]
    return search?.url
  }

  private static func hasUnsupportedScheme(_ input: String) -> Bool {
    let lowercased = input.lowercased()
    return input.contains("://") || lowercased.hasPrefix("javascript:")
      || lowercased.hasPrefix("data:") || lowercased.hasPrefix("file:")
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

  /// `limit` counts every row, including the Open row when input can navigate.
  ///
  /// Return runs the first row. A typed address puts Open first unless a result is already at
  /// that exact address. Typed text puts Search first unless a result's site or title starts
  /// with the text (`gith` selects an open GitHub tab). A leading result moves Open to the end.
  static func results(
    for query: String, in session: BrowserSession,
    bookmarks: [BrowserBookmark], history: [BrowserHistoryEntry],
    searchEngine: BrowserSearchEngine, limit: Int
  ) -> [CommandResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let openURL = NavigationInput.destination(for: query, searchEngine: searchEngine)
    let candidateLimit = openURL == nil ? limit : limit - 1
    let typedAddress = NavigationInput.address(for: query)
    var results: [CommandResult] = []
    var leadingIndex: Int?
    func leads(_ result: CommandResult, _ url: URL?) -> Bool {
      if let typedAddress { return CommandText.sameAddress(url, typedAddress) }
      return CommandText.siteStarts(with: query, url)
        || CommandText.titleStarts(with: query, result.title)
    }
    func append(_ result: CommandResult, url: URL? = nil) -> Bool {
      if leadingIndex == nil, leads(result, url) { leadingIndex = results.count }
      results.append(result)
      return results.count >= candidateLimit
    }

    let orderedSpaces = session.spaces.sorted {
      $0.id == session.selectedSpaceID && $1.id != session.selectedSpaceID
    }
    let profileID = session.selectedSpace.profileID
    let profileName = session.profiles.first { $0.id == profileID }?.name ?? ""
    for favorite in session.favorites where favorite.profileID == profileID {
      let page = session.favoritePage(for: favorite.id)
      guard CommandText.matches(query, CommandFields.favorite(favorite, page: page)) else {
        continue
      }
      let url = page?.tab.url ?? favorite.originalURL
      let domain = CommandText.domain(of: url)
      if append(
        .favorite(favorite, subtitle: "Favorite · \(profileName) profile · \(domain)"), url: url)
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
        guard CommandText.matches(query, CommandFields.tab(tab, folderPath: path)) else {
          return false
        }
        let context = path.isEmpty ? space.name : "\(space.name) · \(path)"
        let domain = CommandText.domain(of: tab.url)
        return append(.tab(tab, space: space.id, subtitle: "\(context) · \(domain)"), url: tab.url)
      }
      for tab in space.orderedTabs {
        if appendTabResult(tab) { break search }
      }
      for folder in space.folders {
        let path = folderPathString(to: folder.id)
        if CommandText.matches(query, [path]) {
          if append(
            CommandResult(
              title: folder.name, subtitle: "\(space.name) · \(path)",
              symbol: "folder", action: .folder(space: space.id, folder: folder.id)))
          {
            break search
          }
        }
      }
      if CommandText.matches(query, [space.name]) {
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
        where CommandText.matches(query, CommandFields.closedTab(entry)) {
          let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
          if append(
            .reopen(entry, subtitle: "Reopen closed tab · \(space.name) · \(profile) profile"),
            url: entry.tab.url)
          {
            break search
          }
        }
        let profile = space.profileID
        let profileName = session.profiles.first { $0.id == profile }?.name ?? ""
        var bookmarked: Set<String> = []
        for item in bookmarks where item.profileID == profile && item.destination != nil {
          guard CommandText.matches(query, CommandFields.bookmark(item)) else { continue }
          bookmarked.insert(item.address!)
          if append(
            .bookmark(item, subtitle: "Bookmark · \(profileName) profile · \(item.path)"),
            url: item.destination)
          {
            break search
          }
        }
        for entry in history
        where entry.profileID == profile && entry.destination != nil
          && !bookmarked.contains(entry.address)
        {
          guard CommandText.matches(query, CommandFields.history(entry)) else { continue }
          if append(
            .history(
              entry,
              subtitle:
                "History · \(profileName) profile · \(entry.lastVisit.formatted(date: .abbreviated, time: .omitted))"
            ), url: entry.destination)
          {
            break search
          }
        }
      }
    }
    guard let openURL else { return results }
    let openRow = CommandResult(
      title: query, subtitle: "Open in \(session.selectedSpace.name)",
      symbol: "arrow.up.right", action: .open(openURL))
    if let leadingIndex {
      results.insert(results.remove(at: leadingIndex), at: 0)
      results.append(openRow)
    } else {
      results.insert(openRow, at: 0)
    }
    return results
  }

}
