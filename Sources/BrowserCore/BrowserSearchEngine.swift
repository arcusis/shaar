// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

public enum BrowserSearchEngine: String, Codable, CaseIterable, Sendable {
  case google
  case duckDuckGo
  case brave
  case kagi
  case startpage
  case ecosia
  case bing
  case perplexity

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    self = Self(rawValue: rawValue) ?? .google
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var displayName: String {
    switch self {
    case .google: "Google"
    case .duckDuckGo: "DuckDuckGo"
    case .brave: "Brave Search"
    case .kagi: "Kagi"
    case .startpage: "Startpage"
    case .ecosia: "Ecosia"
    case .bing: "Bing"
    case .perplexity: "Perplexity"
    }
  }

  /// Search results page and the query parameter it reads.
  public var searchEndpoint: (url: String, queryName: String) {
    switch self {
    case .google: ("https://www.google.com/search", "q")
    case .duckDuckGo: ("https://duckduckgo.com/", "q")
    case .brave: ("https://search.brave.com/search", "q")
    case .kagi: ("https://kagi.com/search", "q")
    case .startpage: ("https://www.startpage.com/sp/search", "query")
    case .ecosia: ("https://www.ecosia.org/search", "q")
    case .bing: ("https://www.bing.com/search", "q")
    case .perplexity: ("https://www.perplexity.ai/search", "q")
    }
  }
}
