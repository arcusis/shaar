import Foundation

public enum NavigationInput {
  public static func isWebURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
  }

  public static func destination(for input: String) -> URL? {
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
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: input)]
    return search.url
  }
}

public enum CommandAction: Hashable, Sendable {
  case open(URL)
  case tab(space: UUID, tab: UUID)
  case space(UUID)
  case folder(space: UUID, folder: UUID)
  case reopen(space: UUID, tab: UUID)
}

public struct CommandResult: Identifiable, Equatable, Sendable {
  public var id: CommandAction { action }
  public let title: String
  public let subtitle: String
  public let symbol: String
  public let action: CommandAction
}

public enum CommandSearch {
  public static func results(for query: String, in session: BrowserSession) -> [CommandResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [CommandResult] = []
    let orderedSpaces = session.spaces.sorted {
      $0.id == session.selectedSpaceID && $1.id != session.selectedSpaceID
    }
    for space in orderedSpaces {
      for tab in space.orderedTabs {
        let path = space.folderPath(to: tab.folderID).reversed().map(\.name).joined(
          separator: " / ")
        guard
          query.isEmpty
            || "\(tab.title) \(tab.url.absoluteString) \(path)".localizedCaseInsensitiveContains(
              query)
        else { continue }
        let context = path.isEmpty ? space.name : "\(space.name) · \(path)"
        results.append(
          CommandResult(
            title: tab.title, subtitle: "\(context) · \(tab.url.host() ?? "")",
            symbol: "rectangle.on.rectangle", action: .tab(space: space.id, tab: tab.id)
          ))
      }
      for folder in space.folders {
        let path = space.folderPath(to: folder.id).reversed().map(\.name).joined(separator: " / ")
        if query.isEmpty || path.localizedCaseInsensitiveContains(query) {
          results.append(
            CommandResult(
              title: folder.name, subtitle: "\(space.name) · \(path)",
              symbol: "folder", action: .folder(space: space.id, folder: folder.id)))
        }
      }
      if query.isEmpty || space.name.localizedCaseInsensitiveContains(query) {
        let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
        results.append(
          CommandResult(
            title: space.name, subtitle: "Switch space · \(profile) profile",
            symbol: space.symbol, action: .space(space.id)
          ))
      }
      if space.id == session.selectedSpaceID {
        for entry in session.recentlyClosedTabs(in: space.id)
        where query.isEmpty
          || "Reopen closed tab \(entry.tab.title) \(entry.tab.url.absoluteString)"
            .localizedCaseInsensitiveContains(query)
        {
          let profile = session.profiles.first { $0.id == space.profileID }?.name ?? ""
          results.append(
            CommandResult(
              title: entry.tab.title,
              subtitle: "Reopen closed tab · \(space.name) · \(profile) profile",
              symbol: "arrow.uturn.backward", action: .reopen(space: space.id, tab: entry.id)))
        }
      }
    }
    if let url = NavigationInput.destination(for: query) {
      results = Array(results.prefix(9))
      results.append(
        CommandResult(
          title: query, subtitle: "Open in \(session.selectedSpace.name)",
          symbol: "arrow.up.right", action: .open(url)
        ))
    }
    return Array(results.prefix(10))
  }
}
