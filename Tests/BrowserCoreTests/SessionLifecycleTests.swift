// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func sessionValidationScaleBenchmark() throws {
  let profile = BrowserProfile(name: "Main")
  let folderIDs = (0..<300).map { _ in UUID() }
  let folders = folderIDs.enumerated().map { index, id in
    BrowserFolder(
      id: id, name: "Folder \(index)", parentID: index == 0 ? nil : folderIDs[index - 1],
      isPinned: false)
  }
  let tabs = (0..<3_000).map { index in
    BrowserTab(
      url: URL(string: "https://example.com/\(index)")!, title: "Tab \(index)",
      isPinned: false, folderID: folderIDs[index % folderIDs.count])
  }
  let space = BrowserSpace(
    profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: tabs, folders: folders)
  let session = try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  #expect(throws: Never.self) { try session.validate() }

  var invalidSession = session
  var invalidSpace = invalidSession.spaces[0]
  invalidSpace.tabs[0].folderID = UUID()
  invalidSession.spaces[0] = invalidSpace
  #expect(throws: SessionError.invalidState) { try invalidSession.validate() }

  let start = ContinuousClock.now
  for _ in 0..<10 { try session.validate() }
  print("sessionValidationScaleBenchmark: \(start.duration(to: .now))")
}

@Test func keepAliveTabSurvivesLegacyDecodeAndRoundTrip() throws {
  let url = URL(string: "https://example.com/keep")!
  var session = BrowserSession.fresh()
  let opened = session.open(url)
  let tabID = try #require(opened)
  let changed = session.setKeepAlive(true, for: tabID)
  let unchanged = session.setKeepAlive(true, for: tabID)
  #expect(changed && !unchanged)
  let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session))
  #expect(restored.selectedSpace.selectedTab?.keepAlive == true)
  let legacy =
    #"{"id":"00000000-0000-4000-8000-000000000001","url":"https://example.com/keep","title":"Keep","isPinned":false}"#
  let old = try JSONDecoder().decode(BrowserTab.self, from: Data(legacy.utf8))
  #expect(!old.keepAlive)
}

@Test func sessionProfilesNeedANonBlankName() {
  var session = BrowserSession.fresh()
  let created = session.createProfile(name: "  Studio \n")
  let blank = session.createProfile(name: "   ")
  #expect(created != nil && session.profiles.last?.id == created)
  #expect(session.profiles.last?.name == "Studio")
  #expect(blank == nil)
  #expect(session.profiles.count == 3)
}

@Test func tabMetadataUpdatesOnlyWhenSomethingChanged() {
  var session = BrowserSession.fresh()
  let url = URL(string: "https://example.com/start")!
  let tab = session.open(url)!
  let updates = [
    session.updateTab(tab, url: url, title: "Start"),
    session.updateTab(tab, url: url, title: "Start"),
    session.updateTab(tab, url: URL(string: "https://docs.example.com/")!, title: ""),
    session.updateTab(tab, url: URL(string: "file:///etc/hosts")!, title: "Local"),
    session.updateTab(UUID(), url: url, title: "Missing"),
  ]
  #expect(updates == [true, false, true, false, false])
  #expect(session.selectedSpace.selectedTab?.title == "docs.example.com")
}

@Test func whitespacePageTitlesUseHostForTabLabels() throws {
  let url = URL(string: "https://docs.example.com/read")!
  let nativeTab = BrowserTab(url: url, title: " \t ")
  #expect(nativeTab.title == "docs.example.com")

  var session = BrowserSession.fresh()
  let opened = session.open(url)
  let id = try #require(opened)
  let updated = session.updateTab(id, url: url, title: " \n ")
  #expect(!updated)
  #expect(session.selectedSpace.selectedTab?.title == "docs.example.com")
}

@Test func engineTabsJoinTheirProfileAndOnlyForegroundTabsTakeSelection() {
  var session = BrowserSession.fresh()
  let personal = session.spaces[0]
  let work = session.spaces[1]
  let background = BrowserTab(url: URL(string: "https://work.example/report")!)
  let backgroundSpace = session.insertNativeTab(
    background, profileID: work.profileID, openerID: nil, foreground: false)
  #expect(backgroundSpace == work.id)
  #expect(session.selectedSpaceID == personal.id)

  let foreground = BrowserTab(url: URL(string: "https://work.example/inbox")!)
  let foregroundSpace = session.insertNativeTab(
    foreground, profileID: work.profileID, openerID: nil, foreground: true)
  #expect(foregroundSpace == work.id)
  #expect(session.selectedSpaceID == work.id)
  #expect(session.selectedSpace.selectedTabID == foreground.id)

  let duplicate = session.insertNativeTab(
    foreground, profileID: work.profileID, openerID: nil, foreground: true)
  let unknownProfile = session.insertNativeTab(
    BrowserTab(url: URL(string: "https://example.com")!), profileID: UUID(), openerID: nil,
    foreground: true)
  #expect(duplicate == nil && unknownProfile == nil)
}

@Test func foregroundNativeTabRevealsItsCollapsedFolder() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let profile = session.selectedSpace.profileID
  let folder = session.addFolder(name: "Popups", in: space)!
  let collapsed = session.toggleFolder(folder, in: space)
  #expect(collapsed)
  let incoming = BrowserTab(
    url: URL(string: "https://example.com/popup")!, isPinned: true, folderID: folder)

  let inserted = session.insertNativeTab(
    incoming, profileID: profile, openerID: nil, foreground: true)

  #expect(inserted == space)
  #expect(session.selectedSpace.selectedTabID == incoming.id)
  #expect(session.selectedSpace.folderPath(to: folder).allSatisfy { !$0.isCollapsed })
}

@Test func movingSelectedTabRevealsSourceFallbackInsideCollapsedFolder() throws {
  var session = BrowserSession.fresh()
  let source = session.selectedSpaceID
  let profile = session.selectedSpace.profileID
  let fallback = session.open(URL(string: "https://fallback.example")!)!
  let moved = session.open(URL(string: "https://moved.example")!)!
  let folder = session.addFolder(name: "Saved", in: source)!
  let placed = session.moveTab(fallback, from: source, to: source, folderID: folder)
  #expect(placed)
  let collapsed = session.toggleFolder(folder, in: source)
  #expect(collapsed)
  let destination = session.addSpace(name: "Shared", sharingProfile: profile)!
  session.selectSpace(source)
  session.selectTab(moved, in: source)

  let transferred = session.moveTab(moved, from: source, to: destination)
  #expect(transferred)
  session.selectSpace(source)
  #expect(session.selectedSpace.selectedTabID == fallback)
  #expect(session.selectedSpace.folderPath(to: folder).allSatisfy { !$0.isCollapsed })
  try session.validate()
}

@Test func firstBackgroundNativeTabSelectsWithinEmptyDestinationSpace() {
  var session = BrowserSession.fresh()
  let originalSpaceID = session.selectedSpaceID
  let destinationSpace = session.spaces[1]
  let first = BrowserTab(url: URL(string: "https://work.example/first")!)
  let second = BrowserTab(url: URL(string: "https://work.example/second")!)

  let firstDestination = session.insertNativeTab(
    first, profileID: destinationSpace.profileID, openerID: nil, foreground: false)
  let secondDestination = session.insertNativeTab(
    second, profileID: destinationSpace.profileID, openerID: nil, foreground: false)

  #expect(firstDestination == destinationSpace.id)
  #expect(secondDestination == destinationSpace.id)
  #expect(session.selectedSpaceID == originalSpaceID)
  #expect(session.spaces[1].selectedTabID == first.id)
  session.selectSpace(destinationSpace.id)
  #expect(session.selectedSpace.selectedTab?.id == first.id)
}

@Test func removingAProfilesLastSpaceAsksBeforeClosingOpenFavorites() {
  var session = BrowserSession.fresh()
  let personal = session.spaces[0]
  let favorite = session.addFavorite(
    profileID: personal.profileID, originalURL: URL(string: "https://mail.example")!)!
  let refused = [
    session.removeSpace(personal.id),
    session.removeSpace(personal.id, favoriteDisposition: .preserveAsTab),
  ]
  #expect(refused == [false, false])
  #expect(session.spaces.count == 2)

  let removed = session.removeSpace(personal.id, favoriteDisposition: .closePage)
  #expect(removed)
  #expect(session.favoritePage(for: favorite) == nil)
  #expect(session.favorites.map(\.id) == [favorite])
  #expect(session.profiles.contains { $0.id == personal.profileID })

  let last = session.spaces[0].id
  let lastRemoval = [
    session.removeSpace(last), session.removeSpace(last, favoriteDisposition: .closePage),
  ]
  #expect(lastRemoval == [false, false])
}

@Test func sessionErrorsExplainWhyASavedSessionWasRejected() {
  #expect(SessionError.unsupportedVersion.errorDescription?.contains("unsupported") == true)
  #expect(SessionError.invalidState.errorDescription?.contains("invalid") == true)
}

@Test func spaceSymbolsMustBeNamed() {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let updates = [
    session.updateSpaceSymbol(space, symbol: ""),
    session.updateSpaceSymbol(UUID(), symbol: "star"),
    session.updateSpaceSymbol(space, symbol: "star"),
  ]
  #expect(updates == [false, false, true])
  #expect(session.selectedSpace.symbol == "star")
}

@Test func spaceSymbolUpdateRejectsWhitespaceOnlyName() {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let original = session.selectedSpace.symbol

  let changed = session.updateSpaceSymbol(space, symbol: " \t\n ")
  #expect(!changed)
  #expect(session.selectedSpace.symbol == original)
}

@Test func blankSavedSymbolsUseVisibleModelFallbacks() throws {
  let session = BrowserSession.fresh()
  let profile = BrowserProfile(name: "Personal", symbol: " \t ")
  let space = BrowserSpace(
    profileID: profile.id, name: "Personal", symbol: " \t ", tint: .lavender)
  #expect(profile.symbol == nil)
  #expect(space.symbol == "square.stack")

  var json = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
  var profiles = try #require(json["profiles"] as? [[String: Any]])
  var spaces = try #require(json["spaces"] as? [[String: Any]])
  profiles[0]["symbol"] = " \t "
  spaces[0]["symbol"] = " \t "
  json["profiles"] = profiles
  json["spaces"] = spaces
  let restored = try JSONDecoder().decode(
    BrowserSession.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(restored.profiles[0].symbol == nil)
  #expect(restored.spaces[0].symbol == "square.stack")
}
