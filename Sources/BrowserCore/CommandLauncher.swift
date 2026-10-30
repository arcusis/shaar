import Foundation

/// A host menu command the launcher offers as an Action.
public struct LauncherCommand: Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let symbol: String

  public init(id: String, title: String, detail: String, symbol: String) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
  }

  /// Actions match on word prefixes so short queries do not list every command.
  public func matches(_ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    let title = title.lowercased()
    let query = query.lowercased()
    return title.hasPrefix(query)
      || title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .contains { $0.hasPrefix(query) }
  }
}

/// Spotlight-style chips that narrow the launcher to one kind of result.
public enum CommandFilter: String, CaseIterable, Identifiable, Sendable {
  case tabs, history, bookmarks, actions

  public var id: String { rawValue }
  public var title: String { rawValue.capitalized }

  public var symbol: String {
    switch self {
    case .tabs: "rectangle.on.rectangle"
    case .history: "clock"
    case .bookmarks: "star"
    case .actions: "command"
    }
  }

  /// Cycles through no filter and every chip, in chip order.
  public static func cycled(from current: CommandFilter?, by offset: Int) -> CommandFilter? {
    let order: [CommandFilter?] = [nil] + allCases
    let index = order.firstIndex(of: current) ?? 0
    let next = (index + offset % order.count + order.count) % order.count
    return order[next]
  }
}

public struct CommandSection: Identifiable, Equatable, Sendable {
  public let id: String
  /// Empty titles render without a header.
  public let title: String
  public let results: [CommandResult]

  public init(id: String, title: String, results: [CommandResult]) {
    self.id = id
    self.title = title
    self.results = results
  }
}

extension Array where Element == CommandSection {
  public var results: [CommandResult] { flatMap(\.results) }
  public var headerCount: Int { count(where: { !$0.title.isEmpty }) }
}

public struct CommandSources: Sendable {
  public var bookmarks: [BrowserBookmark]
  public var history: [BrowserHistoryEntry]
  public var commands: [LauncherCommand]
  public var searchEngine: BrowserSearchEngine

  public init(
    bookmarks: [BrowserBookmark] = [], history: [BrowserHistoryEntry] = [],
    commands: [LauncherCommand] = [], searchEngine: BrowserSearchEngine = .google
  ) {
    self.bookmarks = bookmarks
    self.history = history
    self.commands = commands
    self.searchEngine = searchEngine
  }
}

/// Groups launcher results into sections: suggestions when empty, ranked hits when typing,
/// and one kind of result when a chip is selected.
public enum CommandLauncher {
  static let suggestedTabLimit = 6
  static let suggestedFavoriteLimit = 6
  static let suggestedClosedLimit = 3
  static let mostVisitedLimit = 4
  static let searchActionLimit = 3
  static let filteredLimit = 20

  public static func sections(
    for query: String, filter: CommandFilter?, in session: BrowserSession,
    sources: CommandSources = CommandSources()
  ) -> [CommandSection] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let sections: [CommandSection]
    switch filter {
    case nil where query.isEmpty: sections = suggestions(in: session, sources: sources)
    case nil: sections = searchSections(for: query, in: session, sources: sources)
    case .tabs: sections = tabSections(for: query, in: session)
    case .history: sections = [historySection(for: query, in: session, sources: sources)]
    case .bookmarks: sections = [bookmarkSection(for: query, in: session, sources: sources)]
    case .actions: sections = [actionSection(for: query, sources: sources, limit: nil)]
    }
    return sections.filter { !$0.results.isEmpty }
  }

  // MARK: Empty query

  static func suggestions(in session: BrowserSession, sources: CommandSources)
    -> [CommandSection]
  {
    let space = session.selectedSpace
    let tabs = space.orderedTabs
    let openTabs = tabs.filter { !$0.isPinned }.prefix(suggestedTabLimit).map {
      CommandResult.tab($0, space: space.id, subtitle: domain(of: $0.url))
    }
    let favorites = favoriteResults(matching: "", in: session)
    let pinned = tabs.filter(\.isPinned).map {
      CommandResult.tab($0, space: space.id, subtitle: domain(of: $0.url))
    }
    let closed = session.recentlyClosedTabs(in: space.id).prefix(suggestedClosedLimit).map {
      CommandResult.reopen($0, subtitle: domain(of: $0.tab.url))
    }
    return [
      CommandSection(id: "open-tabs", title: "Open Tabs", results: Array(openTabs)),
      CommandSection(
        id: "favorites", title: "Favorites & Pinned",
        results: Array((favorites + pinned).prefix(suggestedFavoriteLimit))),
      CommandSection(id: "recently-closed", title: "Recently Closed", results: Array(closed)),
      CommandSection(
        id: "most-visited", title: "Most Visited",
        results: mostVisited(in: session, history: sources.history)),
    ]
  }

  /// Frequently visited pages that are not already open in this Space.
  static func mostVisited(in session: BrowserSession, history: [BrowserHistoryEntry])
    -> [CommandResult]
  {
    let profileID = session.selectedSpace.profileID
    let open = Set(session.selectedSpace.tabs.map { pageKey($0.url) })
    return
      history
      .filter {
        guard $0.profileID == profileID, let url = $0.destination else { return false }
        return !open.contains(pageKey(url))
      }
      .sorted { ($0.visitCount, $0.lastVisit) > ($1.visitCount, $1.lastVisit) }
      .prefix(mostVisitedLimit)
      .map { CommandResult.history($0, subtitle: domain(of: $0.destination)) }
  }

  // MARK: Typed query

  /// Ranked hits keep their existing order; matching Actions come next and Open stays last.
  static func searchSections(
    for query: String, in session: BrowserSession, sources: CommandSources
  ) -> [CommandSection] {
    let actions = actionSection(for: query, sources: sources, limit: searchActionLimit)
    let hits = CommandSearch.results(
      for: query, in: session, bookmarks: sources.bookmarks, history: sources.history,
      searchEngine: sources.searchEngine,
      limit: CommandSearch.resultLimit - actions.results.count)
    return [
      CommandSection(id: "top-hits", title: "", results: hits.filter { !$0.isOpen }),
      actions,
      CommandSection(id: "open", title: "", results: hits.filter(\.isOpen)),
    ]
  }

  // MARK: Chips

  static func tabSections(for query: String, in session: BrowserSession) -> [CommandSection] {
    let orderedSpaces = session.spaces.sorted {
      $0.id == session.selectedSpaceID && $1.id != session.selectedSpaceID
    }
    let tabs = orderedSpaces.lazy.flatMap { space in
      space.orderedTabs.lazy
        .filter { matches(query, $0.title, $0.url.absoluteString) }
        .map { tab in
          CommandResult.tab(
            tab, space: space.id, subtitle: tabSubtitle(tab, in: space, session: session))
        }
    }
    let closed = session.recentlyClosedTabs(in: session.selectedSpaceID)
      .filter { matches(query, $0.tab.title, $0.tab.url.absoluteString) }
      .prefix(suggestedClosedLimit)
      .map { CommandResult.reopen($0, subtitle: domain(of: $0.tab.url)) }
    return [
      CommandSection(id: "tabs", title: "Open Tabs", results: Array(tabs.prefix(filteredLimit))),
      CommandSection(
        id: "favorites", title: "Favorites",
        results: Array(favoriteResults(matching: query, in: session).prefix(filteredLimit))),
      CommandSection(id: "recently-closed", title: "Recently Closed", results: Array(closed)),
    ]
  }

  static func historySection(
    for query: String, in session: BrowserSession, sources: CommandSources
  ) -> CommandSection {
    let profileID = session.selectedSpace.profileID
    let results = sources.history.lazy
      .filter {
        $0.profileID == profileID && $0.destination != nil
          && matches(query, $0.title, $0.address)
      }
      .prefix(filteredLimit)
      .map { CommandResult.history($0, subtitle: domain(of: $0.destination)) }
    return CommandSection(id: "history", title: "History", results: Array(results))
  }

  static func bookmarkSection(
    for query: String, in session: BrowserSession, sources: CommandSources
  ) -> CommandSection {
    let profileID = session.selectedSpace.profileID
    let results = sources.bookmarks.lazy
      .filter {
        $0.profileID == profileID && $0.destination != nil
          && matches(query, $0.title, $0.address ?? "", $0.path)
      }
      .prefix(filteredLimit)
      .map { CommandResult.bookmark($0, subtitle: domain(of: $0.destination)) }
    return CommandSection(id: "bookmarks", title: "Bookmarks", results: Array(results))
  }

  static func actionSection(for query: String, sources: CommandSources, limit: Int?)
    -> CommandSection
  {
    let matching = sources.commands.filter { $0.matches(query) }
    let limited = limit.map { Array(matching.prefix($0)) } ?? matching
    return CommandSection(
      id: "actions", title: "Actions", results: limited.map(CommandResult.command))
  }

  // MARK: Shared helpers

  static func favoriteResults(matching query: String, in session: BrowserSession)
    -> [CommandResult]
  {
    let profileID = session.selectedSpace.profileID
    let pages = Dictionary(
      session.favoritePages.map { ($0.favoriteID, $0) }, uniquingKeysWith: { first, _ in first })
    return session.favorites.compactMap { favorite in
      guard favorite.profileID == profileID else { return nil }
      let url = pages[favorite.id]?.tab.url ?? favorite.originalURL
      guard matches(query, favorite.title, favorite.originalURL.absoluteString, url.absoluteString)
      else { return nil }
      return CommandResult.favorite(favorite, subtitle: domain(of: url))
    }
  }

  static func tabSubtitle(_ tab: BrowserTab, in space: BrowserSpace, session: BrowserSession)
    -> String
  {
    let domain = domain(of: tab.url)
    return space.id == session.selectedSpaceID ? domain : "\(space.name) · \(domain)"
  }

  static func matches(_ query: String, _ fields: String...) -> Bool {
    query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }

  /// Compares pages so "https://site.example" and "https://site.example/" are one page.
  static func pageKey(_ url: URL) -> String {
    let address = url.absoluteString
    return address.hasSuffix("/") ? String(address.dropLast()) : address
  }

  /// The grey secondary text on a row: the host without a leading "www.".
  public static func domain(of url: URL?) -> String {
    guard let url else { return "" }
    let host = url.host() ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}
