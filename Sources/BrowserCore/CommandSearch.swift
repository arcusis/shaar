// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum NavigationInput {
  public static func isWebURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
      && url.user == nil && url.password == nil
      && (url.port.map { (1...65535).contains($0) } ?? true)
  }

  /// Only engine-requested Node inspector frontends may use Chromium's internal scheme.
  public static func isDevToolsFrontendURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "devtools", url.host()?.lowercased() == "devtools",
      url.user == nil, url.password == nil, url.port == nil, url.fragment == nil
    else { return false }
    return ["/bundled/js_app.html", "/bundled/inspector.html", "/bundled/node_app.html"]
      .contains(url.path())
  }

  /// The input as a web address (`https://…`, `example.com`, `localhost:3000`), or nil when
  /// it is text to search for or uses an unsupported scheme.
  public static func address(for input: String) -> URL? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    if let url = URL(string: input), isWebURL(url) { return url }
    if hasUnsupportedScheme(input) { return nil }
    // An email's @ is URL user-info syntax when a scheme is inferred; keep bare email
    // addresses in the search path while still allowing @ in a URL path.
    let host = String(input.prefix { !"/?#".contains($0) })
    let normalizedHost = host.lowercased()
    guard !input.contains(where: \.isWhitespace), !host.contains("@"),
      host.contains(".") || normalizedHost == "localhost" || normalizedHost.hasPrefix("localhost:")
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
      || lowercased.hasPrefix("mailto:")
  }
}

public enum CommandAction: Hashable, Sendable {
  case open(URL)
  case providerSearch(URL)
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

/// A connected provider whose signed-in pages can handle a search without an app registration.
public enum CommandSearchProvider: String, Equatable, Sendable {
  case google
  case microsoft
}

/// First-party search pages available for a connected profile.
public enum CommandProviderSearch {
  private struct Service {
    let name: String
    let keyword: String
    let baseURL: String
    let queryName: String?
    let fragmentPrefix: String?
  }

  private static let google: [Service] = [
    Service(
      name: "Gmail", keyword: "gmail", baseURL: "https://mail.google.com/mail/u/0/", queryName: nil,
      fragmentPrefix: "search/"),
    Service(
      name: "Drive", keyword: "drive", baseURL: "https://drive.google.com/drive/u/0/search",
      queryName: "q", fragmentPrefix: nil),
    Service(
      name: "Calendar", keyword: "calendar",
      baseURL: "https://calendar.google.com/calendar/u/0/r/search", queryName: "q",
      fragmentPrefix: nil),
  ]

  private static let microsoft: [Service] = [
    Service(
      name: "Outlook", keyword: "outlook", baseURL: "https://outlook.office.com/mail/search",
      queryName: "q", fragmentPrefix: nil),
    Service(
      name: "OneDrive", keyword: "onedrive", baseURL: "https://onedrive.live.com/?qt=search",
      queryName: "q", fragmentPrefix: nil),
    Service(
      name: "Teams", keyword: "teams", baseURL: "https://teams.microsoft.com/v2/",
      queryName: "search", fragmentPrefix: nil),
  ]

  public static func supports(keyword: String, provider: CommandSearchProvider) -> Bool {
    let services = provider == .google ? google : microsoft
    return services.contains { $0.keyword == keyword.lowercased() }
  }

  /// Builds service rows for a query. A service keyword followed by whitespace narrows to that row.
  public static func results(
    for query: String, provider: CommandSearchProvider?
  ) -> [CommandResult] {
    guard let provider else { return [] }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let services = provider == .google ? google : microsoft
    let lowered = query.lowercased()
    guard
      (google + microsoft).contains(where: {
        hasKeywordSeparator(lowered, keyword: $0.keyword)
      })
    else { return [] }
    let requestedService = (google + microsoft).first {
      hasKeywordSeparator(lowered, keyword: $0.keyword)
    }
    if let requestedService,
      !services.contains(where: { $0.keyword == requestedService.keyword })
    {
      return []
    }
    let narrowed = services.first { hasKeywordSeparator(lowered, keyword: $0.keyword) }
    return services.compactMap { service in
      if let narrowed, narrowed.keyword != service.keyword { return nil }
      let term: String
      if narrowed == nil {
        term = query
      } else {
        term = String(query.dropFirst(service.keyword.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !term.isEmpty else { return nil }
      guard let url = url(for: service, query: term) else { return nil }
      return CommandResult(
        title: BrowserLocalization.format(
          "Search %@ for “%@”", arguments: [.string(service.name), .string(term)]),
        subtitle: service.name,
        symbol: "magnifyingglass",
        action: .providerSearch(url))
    }
  }

  private static func hasKeywordSeparator(_ query: String, keyword: String) -> Bool {
    guard query.hasPrefix(keyword), query.count > keyword.count else { return false }
    return query[query.index(query.startIndex, offsetBy: keyword.count)].isWhitespace
  }

  /// URL construction is public for focused coverage of service-specific encoding.
  public static func url(for serviceName: String, query: String) -> URL? {
    let service = (google + microsoft).first { $0.name == serviceName }
    guard let service else { return nil }
    return url(for: service, query: query)
  }

  private static func url(for service: Service, query: String) -> URL? {
    guard var components = URLComponents(string: service.baseURL) else { return nil }
    if let queryName = service.queryName {
      components.queryItems =
        (components.queryItems ?? []) + [
          URLQueryItem(name: queryName, value: query)
        ]
    } else if let fragmentPrefix = service.fragmentPrefix {
      let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
      guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
        return nil
      }
      components.percentEncodedFragment = fragmentPrefix + encoded
    }
    return components.url
  }
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
      title: entry.recoveryTitle, subtitle: subtitle, symbol: "arrow.uturn.backward",
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
    guard limit > 0 else { return [] }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let typedAddress = NavigationInput.address(for: query)
    let completion =
      typedAddress == nil
      ? nil
      : recentURLCompletion(
        for: query, history: history, profileID: session.selectedSpace.profileID)
    let targetAddress = completion ?? typedAddress
    let openURL = completion ?? NavigationInput.destination(for: query, searchEngine: searchEngine)
    let candidateLimit = openURL == nil ? limit : limit - 1
    var results: [CommandResult] = []
    var leadingIndex: Int?
    func leads(_ result: CommandResult, _ url: URL?) -> Bool {
      if let targetAddress { return CommandText.sameAddress(url, targetAddress) }
      return CommandText.siteStarts(with: query, url)
        || CommandText.titleStarts(with: query, result.title)
    }
    func append(_ result: CommandResult, url: URL? = nil) -> Bool {
      guard candidateLimit > 0 else { return true }
      if results.count < candidateLimit {
        if leadingIndex == nil, leads(result, url) { leadingIndex = results.count }
        results.append(result)
      } else if leadingIndex == nil, leads(result, url) {
        results[candidateLimit - 1] = result
        leadingIndex = candidateLimit - 1
      }
      return results.count >= candidateLimit && (targetAddress == nil || leadingIndex != nil)
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
        .favorite(
          favorite,
          subtitle: BrowserLocalization.format(
            "Favorite · %@ profile · %@", arguments: [.string(profileName), .string(domain)])),
        url: url)
      {
        break
      }
    }
    search: for space in orderedSpaces
    where results.count < candidateLimit || (targetAddress != nil && leadingIndex == nil) {
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
        if CommandText.matches(query, path) {
          if append(
            CommandResult(
              title: folder.name, subtitle: "\(space.name) · \(path)",
              symbol: "folder", action: .folder(space: space.id, folder: folder.id)))
          {
            break search
          }
        }
      }
      if CommandText.matches(query, space.name) {
        let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
        if append(
          CommandResult(
            title: space.name,
            subtitle: BrowserLocalization.format(
              "Switch space · %@ profile", arguments: [.string(profile)]),
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
            .reopen(
              entry,
              subtitle: BrowserLocalization.format(
                "Reopen closed tab · %@ · %@ profile",
                arguments: [.string(space.name), .string(profile)])),
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
            .bookmark(
              item,
              subtitle: BrowserLocalization.format(
                "Bookmark · %@ profile · %@", arguments: [.string(profileName), .string(item.path)])
            ),
            url: item.destination)
          {
            break search
          }
        }
        for entry in history {
          guard entry.profileID == profile, !bookmarked.contains(entry.address),
            let destination = entry.destination
          else { continue }
          guard CommandText.matches(query, CommandFields.history(entry)) else { continue }
          if append(
            .history(
              entry,
              subtitle:
                BrowserLocalization.format(
                  "History · %@ profile · %@",
                  arguments: [
                    .string(profileName),
                    .string(
                      entry.lastVisit.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .omitted)
                          .locale(
                            BrowserLanguage.currentLaunchLanguage == .hebrew
                              ? Locale(identifier: "he") : .autoupdatingCurrent))),
                  ])
            ), url: destination)
          {
            break search
          }
        }
      }
    }
    guard let openURL else { return results }
    let openRow = CommandResult(
      title: completion?.absoluteString ?? query,
      subtitle: BrowserLocalization.format(
        "Open in %@", arguments: [.string(session.selectedSpace.name)]),
      symbol: "arrow.up.right", action: .open(openURL))
    if let leadingIndex {
      results.insert(results.remove(at: leadingIndex), at: 0)
      results.append(openRow)
    } else {
      results.insert(openRow, at: 0)
    }
    return results
  }

  private static func recentURLCompletion(
    for query: String, history: [BrowserHistoryEntry], profileID: UUID
  ) -> URL? {
    let prefix = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { return nil }
    var match: (url: URL, lastVisit: Date)?
    for entry in history where entry.profileID == profileID {
      guard let url = entry.destination else { continue }
      let address = url.absoluteString.lowercased()
      let withoutScheme = address.replacingOccurrences(
        of: #"^https?://"#, with: "", options: .regularExpression)
      guard address.hasPrefix(prefix) || withoutScheme.hasPrefix(prefix) else { continue }
      if match.map({ entry.lastVisit > $0.lastVisit }) ?? true {
        match = (url, entry.lastVisit)
      }
    }
    return match?.url
  }

}
