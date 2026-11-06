// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func providerSearchURLsEncodeEachServiceQuery() throws {
  let query = "annual plan + Q2/#"
  let gmail = try #require(CommandProviderSearch.url(for: "Gmail", query: query))
  #expect(
    gmail.absoluteString
      == "https://mail.google.com/mail/u/0/#search/annual%20plan%20%2B%20Q2%2F%23")

  for (service, host, path, name) in [
    ("Drive", "drive.google.com", "/drive/u/0/search", "q"),
    ("Calendar", "calendar.google.com", "/calendar/u/0/r/search", "q"),
    ("Outlook", "outlook.office.com", "/mail/search", "q"),
    ("OneDrive", "onedrive.live.com", "/", "q"),
    ("Teams", "teams.microsoft.com", "/v2", "search"),
  ] {
    let url = try #require(CommandProviderSearch.url(for: service, query: query))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(url.host == host)
    #expect(url.path == path)
    #expect(components.queryItems?.first(where: { $0.name == name })?.value == query)
    if service == "OneDrive" {
      #expect(components.queryItems?.first(where: { $0.name == "qt" })?.value == "search")
    }
  }
}

@Test func providerSearchRowsRequireAnExplicitKeywordAndStayOutOfDefaultResults() throws {
  let profile = BrowserProfile(name: "Personal")
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  var sources = CommandSources()
  sources.providerSearch = .google

  let sections = CommandLauncher.sections(
    for: "budget", filter: nil, in: session, sources: sources)
  #expect(sections.first?.id == "open")
  #expect(
    sections.first?.results.first?.action
      == .open(
        NavigationInput.destination(for: "budget")!))
  #expect(
    !sections.results.contains { if case .providerSearch = $0.action { true } else { false } })

  let narrowed = CommandLauncher.sections(
    for: "gmail budget", filter: .actions, in: session, sources: sources)
  #expect(narrowed.results.map(\.title) == ["Search Gmail for “budget”"])
}

@Test func typedWebAddressDoesNotAddConnectedProviderSearches() {
  let session = BrowserSession.fresh()
  var sources = CommandSources()
  sources.providerSearch = .google

  let sections = CommandLauncher.sections(
    for: "https://example.com/path", filter: nil, in: session, sources: sources)

  #expect(sections.results.first?.action == .open(URL(string: "https://example.com/path")!))
  #expect(sections.results.filter { $0.symbol == "magnifyingglass" }.isEmpty)
}

@Test func providerSearchRowsRequireOneOfTheSupportedConnectedProviders() throws {
  #expect(CommandProviderSearch.results(for: "budget", provider: nil).isEmpty)
  #expect(CommandProviderSearch.results(for: "budget", provider: .google).isEmpty)
  #expect(CommandProviderSearch.results(for: "gmail budget", provider: .google).count == 1)
  #expect(CommandProviderSearch.results(for: "outlook budget", provider: .microsoft).count == 1)
  #expect(CommandProviderSearch.results(for: "gmail budget", provider: .microsoft).isEmpty)
}

@Test func providerKeywordAcceptsPastedWhitespaceSeparator() throws {
  let rows = CommandProviderSearch.results(for: "gmail\tbudget", provider: .google)
  #expect(rows.count == 1)
  #expect(rows.first?.title == "Search Gmail for “budget”")
  #expect(CommandProviderSearch.results(for: "gmail   budget", provider: .google).count == 1)
}
