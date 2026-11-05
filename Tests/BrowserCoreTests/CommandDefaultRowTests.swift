// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

// Return runs the first launcher row, so these cover which row comes first (issue #351).

private func sessionWithGmailFavoriteAndGitHubTab() throws -> (BrowserSession, UUID, UUID) {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let addedFavorite = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://mail.google.com/mail/u/0/")!,
    title: "Inbox - david@example.com")
  let favoriteID = try #require(addedFavorite)
  let openedTab = session.open(URL(string: "https://github.com/arcusis/shaar")!)
  let tab = try #require(openedTab)
  return (session, favoriteID, tab)
}

@Test func typedAddressOpensItInsteadOfAMatchingFavorite() throws {
  let (session, _, _) = try sessionWithGmailFavoriteAndGitHubTab()
  for address in ["google.com", "https://google.com", "localhost:3000"] {
    let results = CommandSearch.results(for: address, in: session)
    let expected = try #require(NavigationInput.address(for: address))
    #expect(results.first?.action == .open(expected))
  }
}

@Test func typedTextSearchesUnlessASiteOrTitleStartsWithIt() throws {
  let (session, _, tabID) = try sessionWithGmailFavoriteAndGitHubTab()
  let spaceID = session.selectedSpaceID

  let search = CommandSearch.results(for: "google", in: session)
  #expect(search.first?.action == .open(NavigationInput.destination(for: "google")!))

  let site = CommandSearch.results(for: "gith", in: session)
  #expect(site.first?.action == .tab(space: spaceID, tab: tabID))
  #expect(site.last?.isOpen == true)

  let title = CommandSearch.results(for: "inbox", in: session)
  #expect(title.first?.title == "Inbox - david@example.com")
}

@Test func typedSitePrefixMatchesUppercaseWWWHost() throws {
  var session = BrowserSession.fresh()
  let opened = session.open(URL(string: "https://WWW.EXAMPLE.COM/page")!)
  let tabID = try #require(opened)

  let results = CommandSearch.results(for: "example", in: session)
  #expect(results.first?.action == .tab(space: session.selectedSpaceID, tab: tabID))
}

@Test func typedExactAddressOfAnOpenTabSwitchesToIt() throws {
  let (session, _, tabID) = try sessionWithGmailFavoriteAndGitHubTab()
  let results = CommandSearch.results(for: "github.com/arcusis/shaar", in: session)
  #expect(results.first?.action == .tab(space: session.selectedSpaceID, tab: tabID))
}

@Test func typedAddressKeepsPathCaseWhenMatchingOpenTabs() throws {
  var session = BrowserSession.fresh()
  let openTab = session.open(URL(string: "https://EXAMPLE.com/EXAMPLE.com")!)
  let tabID = try #require(openTab)
  let typedURL = URL(string: "https://example.com/example.com")!

  let results = CommandSearch.results(for: typedURL.absoluteString, in: session)

  #expect(results.first?.action == .open(typedURL))
  #expect(results.contains { $0.action == .tab(space: session.selectedSpaceID, tab: tabID) })
}

@Test func launcherSectionsPutOpenFirstWhenItIsTheDefaultRow() throws {
  let (session, _, _) = try sessionWithGmailFavoriteAndGitHubTab()
  let sections = CommandLauncher.sections(
    for: "google.com", filter: nil, in: session, sources: CommandSources())
  #expect(sections.first?.id == "open")
}
