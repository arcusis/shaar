import Foundation
import Testing

@testable import BrowserCore

@Test func searchEngineNamesAndRawValuesAreStable() {
  #expect(BrowserSearchEngine.allCases.map(\.rawValue) == ["google", "duckDuckGo", "bing"])
  #expect(BrowserSearchEngine.allCases.map(\.displayName) == ["Google", "DuckDuckGo", "Bing"])
}

@Test func searchDestinationsUseSelectedEndpointAndEncodeQuery() throws {
  let input = "SwiftUI & AppKit"
  let expected = [
    "https://www.google.com/search?q=SwiftUI%20%26%20AppKit",
    "https://duckduckgo.com/?q=SwiftUI%20%26%20AppKit",
    "https://www.bing.com/search?q=SwiftUI%20%26%20AppKit",
  ]

  for (engine, address) in zip(BrowserSearchEngine.allCases, expected) {
    #expect(
      NavigationInput.destination(for: input, searchEngine: engine)?.absoluteString == address)
  }
  #expect(NavigationInput.destination(for: input)?.absoluteString == expected[0])
}

@Test func directWebNavigationAndUnsupportedSchemesIgnoreSearchEngine() {
  for engine in BrowserSearchEngine.allCases {
    let directURL = NavigationInput.destination(
      for: "https://example.com/path?q=1", searchEngine: engine)
    #expect(directURL?.absoluteString == "https://example.com/path?q=1")
    #expect(NavigationInput.destination(for: "javascript:alert(1)", searchEngine: engine) == nil)
    #expect(NavigationInput.destination(for: "file:///etc/passwd", searchEngine: engine) == nil)
    #expect(NavigationInput.destination(for: "custom://host", searchEngine: engine) == nil)
  }
}

@Test func commandSearchKeepsGoogleDefaultAndAcceptsSelectedEngine() throws {
  let session = BrowserSession.fresh()
  let defaultResult = try #require(
    CommandSearch.results(for: "SwiftUI & AppKit", in: session).last)
  let bingResult = try #require(
    CommandSearch.results(for: "SwiftUI & AppKit", in: session, searchEngine: .bing).last)

  #expect(
    defaultResult.action
      == .open(URL(string: "https://www.google.com/search?q=SwiftUI%20%26%20AppKit")!))
  #expect(
    bingResult.action
      == .open(URL(string: "https://www.bing.com/search?q=SwiftUI%20%26%20AppKit")!))
}
