// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Text helpers shared by typed launcher search and the filter chips, so both match the same
/// fields and show the same domains.
enum CommandText {
  /// The grey secondary text on a row: the host without a leading "www.".
  static func domain(of url: URL?) -> String {
    guard let url else { return "" }
    let host = url.host() ?? url.absoluteString
    return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// True when the URL's site (host without `www.`) starts with the non-empty query.
  static func siteStarts(with query: String, _ url: URL?) -> Bool {
    guard !query.isEmpty, url != nil else { return false }
    return domain(of: url).lowercased().hasPrefix(query.lowercased())
  }

  /// True when the title starts with the non-empty query, ignoring case and accents.
  static func titleStarts(with query: String, _ title: String) -> Bool {
    guard !query.isEmpty else { return false }
    return title.range(
      of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: .current)
      != nil
  }

  /// True when both URLs name the same page, ignoring a root slash and host case.
  static func sameAddress(_ url: URL?, _ address: URL) -> Bool {
    guard let url else { return false }
    func key(_ value: URL) -> String {
      var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
      if let scheme = components?.scheme?.lowercased() {
        components?.scheme = scheme
        if (scheme == "https" && components?.port == 443)
          || (scheme == "http" && components?.port == 80)
        {
          components?.port = nil
        }
      }
      if let host = components?.host {
        let normalizedHost = host.lowercased()
        components?.host =
          normalizedHost.hasSuffix(".")
          ? String(normalizedHost.dropLast()) : normalizedHost
      }
      let text = components?.string ?? value.absoluteString
      let hasRootSlash = value.path == "/" && value.query == nil && value.fragment == nil
      return hasRootSlash && text.hasSuffix("/") ? String(text.dropLast()) : text
    }
    return key(url) == key(address)
  }

  /// True when the query is empty or any field contains it, ignoring case.
  static func matches(_ query: String, _ field: String) -> Bool {
    query.isEmpty || field.localizedStandardContains(query)
  }

  static func matches(_ query: String, _ fields: (String, String)) -> Bool {
    query.isEmpty || fields.0.localizedStandardContains(query)
      || fields.1.localizedStandardContains(query)
  }

  static func matches(_ query: String, _ fields: (String, String, String)) -> Bool {
    query.isEmpty || fields.0.localizedStandardContains(query)
      || fields.1.localizedStandardContains(query)
      || fields.2.localizedStandardContains(query)
  }

  static func matches(_ query: String, _ fields: (String, String, String, String)) -> Bool {
    query.isEmpty || fields.0.localizedStandardContains(query)
      || fields.1.localizedStandardContains(query)
      || fields.2.localizedStandardContains(query)
      || fields.3.localizedStandardContains(query)
  }
}

/// The searchable fields of each kind of launcher row.
enum CommandFields {
  static func favorite(_ favorite: BrowserFavorite, page: BrowserFavoritePage?) -> (
    String, String, String, String
  ) {
    (
      favorite.title, favorite.originalURL.absoluteString,
      page?.tab.title ?? "", page?.tab.url.absoluteString ?? "",
    )
  }

  static func tab(_ tab: BrowserTab, folderPath: String = "") -> (String, String, String) {
    (tab.title, tab.url.absoluteString, folderPath)
  }

  /// Includes the row's verb so typing "reopen" lists closed tabs.
  static func closedTab(_ entry: ClosedBrowserTab) -> (String, String, String) {
    (
      BrowserLocalization.string("Reopen closed tab"), entry.tab.title,
      entry.tab.url.absoluteString,
    )
  }

  static func bookmark(_ item: BrowserBookmark) -> (String, String, String) {
    (item.title, item.address ?? "", item.path)
  }

  static func history(_ entry: BrowserHistoryEntry) -> (String, String) {
    (entry.title, entry.address)
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
