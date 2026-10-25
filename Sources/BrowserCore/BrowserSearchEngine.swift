public enum BrowserSearchEngine: String, Codable, CaseIterable, Sendable {
  case google
  case duckDuckGo
  case bing

  public var displayName: String {
    switch self {
    case .google: "Google"
    case .duckDuckGo: "DuckDuckGo"
    case .bing: "Bing"
    }
  }
}
