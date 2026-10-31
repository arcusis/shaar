import Foundation

/// Text helpers shared by typed launcher search and the filter chips, so both match the same
/// fields and show the same domains.
public enum CommandText {
  /// The grey secondary text on a row: the host without a leading "www.".
  public static func domain(of url: URL?) -> String {
    guard let url else { return "" }
    let host = url.host() ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// True when the query is empty or any field contains it, ignoring case.
  public static func matches(_ query: String, _ fields: [String]) -> Bool {
    query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}

/// The searchable fields of each kind of launcher row.
enum CommandFields {
  static func favorite(_ favorite: BrowserFavorite, page: BrowserFavoritePage?) -> [String] {
    [
      favorite.title, favorite.originalURL.absoluteString,
      page?.tab.title ?? "", page?.tab.url.absoluteString ?? "",
    ]
  }

  static func tab(_ tab: BrowserTab, folderPath: String = "") -> [String] {
    [tab.title, tab.url.absoluteString, folderPath]
  }

  /// Includes the row's verb so typing "reopen" lists closed tabs.
  static func closedTab(_ entry: ClosedBrowserTab) -> [String] {
    ["Reopen closed tab", entry.tab.title, entry.tab.url.absoluteString]
  }

  static func bookmark(_ item: BrowserBookmark) -> [String] {
    [item.title, item.address ?? "", item.path]
  }

  static func history(_ entry: BrowserHistoryEntry) -> [String] {
    [entry.title, entry.address]
  }
}

/// Keeps the best `limit` elements seen so far without sorting the whole input.
struct TopRanked<Element> {
  let limit: Int
  let ranksHigher: (Element, Element) -> Bool
  private(set) var items: [Element] = []

  init(limit: Int, ranksHigher: @escaping (Element, Element) -> Bool) {
    self.limit = limit
    self.ranksHigher = ranksHigher
  }

  /// Whether the element would make the cut; check before doing expensive work on it.
  func admits(_ element: Element) -> Bool {
    guard limit > 0 else { return false }
    guard items.count == limit, let last = items.last else { return true }
    return ranksHigher(element, last)
  }

  mutating func insert(_ element: Element) {
    guard admits(element) else { return }
    let index = items.firstIndex { ranksHigher(element, $0) } ?? items.count
    items.insert(element, at: index)
    if items.count > limit { items.removeLast() }
  }
}
