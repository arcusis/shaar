import BrowserCore
import Foundation
import Testing

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
