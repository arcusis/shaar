// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func searchEngineNamesAndRawValuesAreStable() {
  #expect(
    BrowserSearchEngine.allCases.map(\.rawValue) == [
      "google", "duckDuckGo", "brave", "kagi", "startpage", "ecosia", "bing", "perplexity",
    ])
  #expect(
    BrowserSearchEngine.allCases.map(\.displayName) == [
      "Google", "DuckDuckGo", "Brave Search", "Kagi", "Startpage", "Ecosia", "Bing", "Perplexity",
    ])
}

@Test func unknownStoredSearchEngineDecodesAsGoogle() throws {
  let decoded = try JSONDecoder().decode(BrowserSearchEngine.self, from: Data(#""yahoo""#.utf8))
  #expect(decoded == .google)
}

@Test func searchDestinationsUseSelectedEndpointAndEncodeQuery() throws {
  let input = "SwiftUI & AppKit"
  let expected = [
    "https://www.google.com/search?q=SwiftUI%20%26%20AppKit",
    "https://duckduckgo.com/?q=SwiftUI%20%26%20AppKit",
    "https://search.brave.com/search?q=SwiftUI%20%26%20AppKit",
    "https://kagi.com/search?q=SwiftUI%20%26%20AppKit",
    "https://www.startpage.com/sp/search?query=SwiftUI%20%26%20AppKit",
    "https://www.ecosia.org/search?q=SwiftUI%20%26%20AppKit",
    "https://www.bing.com/search?q=SwiftUI%20%26%20AppKit",
    "https://www.perplexity.ai/search?q=SwiftUI%20%26%20AppKit",
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
    #expect(NavigationInput.destination(for: "chrome://settings", searchEngine: engine) == nil)
    #expect(NavigationInput.destination(for: "devtools://devtools/bundled/js_app.html", searchEngine: engine) == nil)
    #expect(NavigationInput.destination(for: "custom://host", searchEngine: engine) == nil)
  }
}

@Test func mailtoInputIsNotInferredAsAWebAddress() {
  for input in ["mailto:alice@example.com", "MAILTO:alice@example.com"] {
    #expect(NavigationInput.address(for: input) == nil)
    #expect(NavigationInput.destination(for: input) == nil)
  }
  #expect(
    NavigationInput.address(for: "example.com:8443")?.absoluteString
      == "https://example.com:8443")
}

@Test func capitalizedLocalhostNavigates() {
  #expect(NavigationInput.address(for: "LOCALHOST")?.host()?.lowercased() == "localhost")
  #expect(NavigationInput.address(for: "LOCALHOST:3000")?.port == 3000)
  #expect(
    NavigationInput.address(for: "LOCALHOST:3000/path")?.absoluteString
      == "https://LOCALHOST:3000/path")
}

@Test func navigationRejectsInvalidWebPorts() {
  for invalid in [URL(string: "https://example.com:0")!, URL(string: "https://example.com:99999")!]
  {
    #expect(!NavigationInput.isWebURL(invalid))
    #expect(NavigationInput.address(for: invalid.absoluteString) == nil)
  }
  #expect(NavigationInput.address(for: "https://example.com:65535")?.port == 65535)
}

@Test func bareEmailAddressSearchesInsteadOfOpeningItsDomain() throws {
  let input = "alice@example.com"
  #expect(NavigationInput.address(for: input) == nil)
  let destination = try #require(NavigationInput.destination(for: input))
  let query = URLComponents(url: destination, resolvingAgainstBaseURL: false)?.queryItems?
    .first { $0.name == "q" }?.value
  #expect(destination.host() == "www.google.com")
  #expect(query == input)
  #expect(NavigationInput.address(for: "https://alice@example.com") == nil)
  #expect(
    NavigationInput.address(for: "example.com/path@alice")?.absoluteString
      == "https://example.com/path@alice")

  let result = CommandSearch.results(for: input, in: BrowserSession.fresh()).first
  #expect(result?.action == .open(destination))
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

@Test func searchEnginesBuildEncodedURLsForUnicodeQueries() throws {
  let query = "café 東京 search"
  let expectedHosts = [
    "www.google.com", "duckduckgo.com", "search.brave.com", "kagi.com",
    "www.startpage.com", "www.ecosia.org", "www.bing.com", "www.perplexity.ai",
  ]

  for (engine, host) in zip(BrowserSearchEngine.allCases, expectedHosts) {
    let destination = try #require(NavigationInput.destination(for: query, searchEngine: engine))
    #expect(destination.host() == host)
    #expect(
      URLComponents(url: destination, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == engine.searchEndpoint.queryName })?.value == query)
    #expect(destination.absoluteString.contains("%20"))
  }
}
