import Foundation
import Testing

@testable import BrowserCore

@Test func favoritesKeepOriginalAddressSeparateFromWindowNavigationAndSpaceSelection() throws {
  var session = BrowserSession.fresh()
  let firstSpace = session.selectedSpaceID
  let profileID = session.selectedSpace.profileID
  let firstID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://mail.example.com")!, title: "Mail")
  let first = try #require(firstID)
  let secondID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://video.example.com")!, title: "Video")
  let second = try #require(secondID)
  let firstPage = try #require(session.favoritePages.first { $0.favoriteID == first })
  let secondPage = try #require(session.favoritePages.first { $0.favoriteID == second })
  #expect(firstPage.tab.id != secondPage.tab.id)

  let ordinary = session.open(URL(string: "https://ordinary.example.com")!)!
  let sharedSpaceID = session.addSpace(name: "Shared", sharingProfile: profileID)
  let sharedSpace = try #require(sharedSpaceID)
  session.selectOrdinaryTab(ordinary, in: firstSpace)
  let selectedFirst = session.selectFavorite(first, in: firstSpace)
  #expect(selectedFirst)
  #expect(session.selectedSpaceID == firstSpace)
  #expect(session.selectedSpace.selectedTabID == ordinary)
  #expect(session.selectedPage == .favorite(firstPage))
  let selectedSecond = session.selectFavorite(second, in: sharedSpace)
  #expect(selectedSecond)
  #expect(session.selectedPage == .favorite(secondPage))
  #expect(session.spaces.first { $0.id == firstSpace }?.selectedFavoriteID == first)

  let navigationChanged = session.updateFavoritePage(
    first, url: URL(string: "https://mail.example.com/inbox")!, title: "Inbox")
  #expect(navigationChanged)
  #expect(
    session.favorites.first { $0.id == first }?.originalURL.absoluteString
      == "https://mail.example.com")
  #expect(
    session.favoritePages.first { $0.favoriteID == first }?.tab.url.absoluteString
      == "https://mail.example.com/inbox")
  session.selectSpace(firstSpace)
  #expect(session.selectedFavorite?.id == first)
  #expect(session.selectedPage?.favoritePage?.favoriteID == first)
  session.selectOrdinaryTab(ordinary, in: firstSpace)
  #expect(session.selectedFavorite == nil)
  #expect(session.selectedSpace.selectedTabID == ordinary)
  try session.validate()

  let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session))
  #expect(restored == session)
}

@Test func closeAndUnfavoriteRequireExplicitDispositionAndPreserveCurrentAddress() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://example.com/start")!, title: "Start")
  let favorite = try #require(favoriteID)
  let pageID = try #require(session.favoritePages.first { $0.favoriteID == favorite }?.tab.id)
  let updated = session.updateFavoritePage(
    favorite, url: URL(string: "https://example.com/current")!, title: "Current")
  #expect(updated)
  let preserved = session.removeFavorite(favorite, disposition: .preserveAsTab)
  #expect(preserved)
  #expect(session.favorites.isEmpty)
  #expect(session.favoritePages.isEmpty)
  #expect(session.selectedSpace.tabs.contains { $0.id == pageID && !$0.isPinned })
  #expect(session.selectedSpace.selectedTab?.url.absoluteString == "https://example.com/current")
  try session.validate()

  let closeFavoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://example.net")!)
  let closeFavorite = try #require(closeFavoriteID)
  let closePageID = try #require(
    session.favoritePages.first { $0.favoriteID == closeFavorite }?.tab.id)
  let pageClosed = session.closeFavoritePage(closeFavorite)
  #expect(pageClosed)
  #expect(session.favoritePages.isEmpty)
  let reopenedID = session.openFavorite(closeFavorite)
  let reopenedPageID = try #require(reopenedID)
  #expect(reopenedPageID != closePageID)
  #expect(
    session.favoritePages.first { $0.favoriteID == closeFavorite }?.tab.url.absoluteString
      == "https://example.net")
  let closed = session.removeFavorite(closeFavorite, disposition: .closePage)
  #expect(closed)
  #expect(!session.selectedSpace.tabs.contains { $0.id == reopenedPageID })
  try session.validate()
}

@Test func ordinaryNavigationDoesNotUpdateFavoriteAndStaleSelectionRejects() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://example.com")!)
  let favorite = try #require(favoriteID)
  let page = try #require(session.favoritePages.first { $0.favoriteID == favorite })
  let staleUpdate = session.updateFavoritePage(
    UUID(), url: URL(string: "https://foreign.example")!, title: "Foreign")
  #expect(!staleUpdate)
  let foreignSelection = session.selectFavorite(favorite, in: session.spaces[1].id)
  #expect(!foreignSelection)
  session.selectSpace(session.spaces[0].id)
  let selected = session.selectFavorite(favorite, in: session.selectedSpaceID)
  #expect(selected)
  let beforeInvalidOrdinarySelection = session
  session.selectOrdinaryTab(UUID(), in: session.selectedSpaceID)
  #expect(session.selectedSpace.selectedFavoriteID == favorite)
  #expect(session.favoritePages.first { $0.favoriteID == favorite } == page)
  #expect(
    session.spaces[0].selectedFavoriteID
      == beforeInvalidOrdinarySelection.spaces[0].selectedFavoriteID)
}

@Test func preserveAsTabUsesActiveSharedProfileSpace() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let first = session.selectedSpaceID
  let secondID = session.addSpace(name: "Second shared", sharingProfile: profile)
  let second = try #require(secondID)
  let favoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://example.com/start")!)
  let favorite = try #require(favoriteID)
  let selected = session.selectFavorite(favorite, in: second)
  #expect(selected)
  let updated = session.updateFavoritePage(
    favorite, url: URL(string: "https://example.com/current")!, title: "Current")
  #expect(updated)
  let removed = session.removeFavorite(favorite, disposition: .preserveAsTab)
  #expect(removed)
  #expect(session.selectedSpaceID == second)
  #expect(session.spaces.first { $0.id == first }?.tabs.isEmpty == true)
  #expect(session.selectedSpace.selectedTab?.url.absoluteString == "https://example.com/current")
  try session.validate()
}

@Test func sessionV1V2V3UpgradeWithoutRewritingLegacyBytes() throws {
  let session = BrowserSession.fresh()
  let current =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
  for version in 1...3 {
    var legacy = current
    legacy["version"] = version
    legacy.removeValue(forKey: "favorites")
    legacy.removeValue(forKey: "favoritePages")
    var spaces = legacy["spaces"] as! [[String: Any]]
    spaces = spaces.map { source in
      var space = source
      space.removeValue(forKey: "selectedFavoriteID")
      if version == 1 { space.removeValue(forKey: "folders") }
      return space
    }
    legacy["spaces"] = spaces
    if version < 3 { legacy.removeValue(forKey: "closedTabs") }
    let bytes = try JSONSerialization.data(withJSONObject: legacy)
    let restored = try JSONDecoder().decode(BrowserSession.self, from: bytes)
    #expect(restored.version == 4)
    #expect(restored.favorites.isEmpty && restored.favoritePages.isEmpty)
    #expect(restored.spaces.map(\.id) == session.spaces.map(\.id))

    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: file.url)
    #expect(try file.load() == restored)
    #expect(try Data(contentsOf: file.url) == bytes)
  }
}

@Test func sessionRejectsFutureOrMalformedFavoriteState() throws {
  var object =
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(BrowserSession.fresh())) as! [String: Any]
  object["version"] = 5
  let future = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: SessionError.self) { try JSONDecoder().decode(BrowserSession.self, from: future) }

  object["version"] = 4
  object.removeValue(forKey: "favoritePages")
  let missing = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserSession.self, from: missing) }
}

@Test func favoritePageTabIDsAreUniqueAndNoSpaceOrBlankTitleCannotCreateInvalidState() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let firstID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://one.example")!)
  let first = try #require(firstID)
  let secondID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://two.example")!)
  let second = try #require(secondID)
  var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
  var pages = wire["favoritePages"] as! [[String: Any]]
  var secondPage = pages[1]
  var secondTab = secondPage["tab"] as! [String: Any]
  let firstTab = pages[0]["tab"] as! [String: Any]
  secondTab["id"] = firstTab["id"]
  secondPage["tab"] = secondTab
  pages[1] = secondPage
  wire["favoritePages"] = pages
  let duplicateIDs = try JSONSerialization.data(withJSONObject: wire)
  #expect(throws: SessionError.self) {
    try JSONDecoder().decode(BrowserSession.self, from: duplicateIDs)
  }

  let state = session
  let blank = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://blank.example")!, title: " \n ")
  #expect(blank == nil && session == state)
  let removedSpace = session.selectedSpaceID
  let didRemove = session.removeSpace(removedSpace, favoriteDisposition: .closePage)
  #expect(didRemove)
  let beforeUnreachableAdd = session
  let unreachable = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://unreachable.example")!)
  #expect(unreachable == nil && session == beforeUnreachableAdd)
  try session.validate()
  #expect(session.favorites.map(\.id) == [first, second])
}

@Test func pageLookupReportsOrdinaryAndFavoritePageProfilesAndFavoriteReorderIsProfileBound() throws
{
  var session = BrowserSession.fresh()
  let firstSpace = session.selectedSpace
  let secondSpace = session.spaces[1]
  let firstFavoriteID = session.addFavorite(
    profileID: firstSpace.profileID, originalURL: URL(string: "https://first.example")!)
  let firstFavorite = try #require(firstFavoriteID)
  let nextFavoriteID = session.addFavorite(
    profileID: firstSpace.profileID, originalURL: URL(string: "https://next.example")!)
  let nextFavorite = try #require(nextFavoriteID)
  let foreignFavoriteID = session.addFavorite(
    profileID: secondSpace.profileID, originalURL: URL(string: "https://foreign.example")!)
  let foreignFavorite = try #require(foreignFavoriteID)
  let ordinaryID = session.open(URL(string: "https://ordinary.example")!)!
  let favoriteTabID = try #require(
    session.favoritePages.first { $0.favoriteID == firstFavorite }?.tab.id)
  #expect(session.page(forTabID: ordinaryID)?.tab.id == ordinaryID)
  #expect(session.profileID(forTabID: ordinaryID) == firstSpace.profileID)
  #expect(session.page(forTabID: favoriteTabID)?.tab.id == favoriteTabID)
  #expect(session.profileID(forTabID: favoriteTabID) == firstSpace.profileID)
  #expect(session.favorites(for: firstSpace.profileID).map(\.id) == [firstFavorite, nextFavorite])
  let normalizedTitle = session.updateFavoritePage(
    firstFavorite, url: URL(string: "https://first.example/current")!, title: " \t ")
  #expect(normalizedTitle)
  #expect(
    session.favoritePages.first { $0.favoriteID == firstFavorite }?.tab.title
      == "first.example")

  let moved = session.moveFavorite(nextFavorite, in: firstSpace.profileID, before: firstFavorite)
  #expect(moved)
  #expect(session.favorites(for: firstSpace.profileID).map(\.id) == [nextFavorite, firstFavorite])
  let reordered = session
  let wrongSourceProfile = session.moveFavorite(
    nextFavorite, in: secondSpace.profileID, before: firstFavorite)
  let foreignTarget = session.moveFavorite(
    firstFavorite, in: firstSpace.profileID, before: foreignFavorite)
  #expect(!wrongSourceProfile)
  #expect(!foreignTarget)
  #expect(session == reordered)
  #expect(session.favorites(for: secondSpace.profileID).map(\.id) == [foreignFavorite])
}

@Test func promoteTabToFavoriteReusesNativeIDAndKeepsOrdinaryFallback() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let profile = session.selectedSpace.profileID
  let pageID = session.open(URL(string: "https://promote.example/current")!)!
  session.togglePin(pageID)
  let folder = session.addFolder(name: "Saved", in: space)!
  let pinnedIntoFolder = session.moveTab(pageID, from: space, to: space, folderID: folder)
  #expect(pinnedIntoFolder)
  let fallbackID = session.open(URL(string: "https://fallback.example")!)!
  session.selectTab(pageID, in: space)
  let closedBefore = session.closedTabs

  let favoriteID = session.promoteTabToFavorite(pageID, in: space)
  let favorite = try #require(favoriteID)
  let page = try #require(session.favoritePages.first { $0.favoriteID == favorite })
  #expect(page.tab.id == pageID)
  #expect(page.tab.url.absoluteString == "https://promote.example/current")
  #expect(page.tab.isPinned == false && page.tab.folderID == nil)
  #expect(session.spaces.first { $0.id == space }?.tabs.contains { $0.id == pageID } == false)
  #expect(session.selectedSpaceID == space)
  #expect(session.selectedSpace.selectedFavoriteID == favorite)
  #expect(session.selectedSpace.selectedTabID == fallbackID)
  #expect(session.closedTabs == closedBefore)
  #expect(session.favorites.first { $0.id == favorite }?.profileID == profile)
  try session.validate()
}

@Test func promotionNormalizesLegacyWhitespaceTitleWithoutChangingPageIdentity() throws {
  var session = BrowserSession.fresh()
  let spaceID = session.selectedSpaceID
  let tabID = session.open(URL(string: "https://legacy-title.example/current")!)!
  var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
  var spaces = wire["spaces"] as! [[String: Any]]
  var space = spaces[0]
  var tabs = space["tabs"] as! [[String: Any]]
  tabs[0]["title"] = "  \n "
  space["tabs"] = tabs
  spaces[0] = space
  wire["spaces"] = spaces
  session = try JSONDecoder().decode(
    BrowserSession.self, from: JSONSerialization.data(withJSONObject: wire))

  let favoriteID = session.promoteTabToFavorite(tabID, in: spaceID)
  let favorite = try #require(favoriteID)
  let page = try #require(session.favoritePages.first { $0.favoriteID == favorite })
  #expect(page.tab.id == tabID)
  #expect(page.tab.url.absoluteString == "https://legacy-title.example/current")
  #expect(page.tab.title == "legacy-title.example")
  #expect(session.favorites.first { $0.id == favorite }?.title == page.tab.title)
  try session.validate()
}

@Test func reopeningClosedOrdinaryTabClearsSelectedFavorite() throws {
  var session = BrowserSession.fresh()
  let spaceID = session.selectedSpaceID
  let profileID = session.selectedSpace.profileID
  let closedTabID = session.open(URL(string: "https://closed.example")!)!
  session.closeTab(closedTabID)
  let favoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://favorite.example")!)!
  let selected = session.selectFavorite(favoriteID, in: spaceID)
  #expect(selected)

  let reopenedID = session.reopenClosedTab(closedTabID, in: spaceID)
  let reopened = try #require(reopenedID)
  #expect(session.selectedSpace.selectedFavoriteID == nil)
  #expect(session.selectedPage?.tab.id == reopened)
  #expect(session.selectedSpace.selectedTabID == reopened)
  try session.validate()
}

@Test func nativeTabInsertionRejectsFavoritePageIDCollisionWithoutMutation() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://favorite.example")!)!
  let favoritePageID = try #require(
    session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id)
  let collision = BrowserTab(
    id: favoritePageID, url: URL(string: "https://native.example")!, title: "Native")
  let before = session

  let inserted = session.insertNativeTab(
    collision, profileID: profileID, openerID: nil, foreground: true)

  #expect(inserted == nil)
  #expect(session == before)
}

@Test func movingBackgroundFallbackDoesNotStealFavoriteSelectionButSelectedOrdinaryDoes() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let firstSpace = session.selectedSpaceID
  let secondSpaceID = session.addSpace(name: "Shared", sharingProfile: profile)
  let secondSpace = try #require(secondSpaceID)
  let favoriteAID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://favorite-a.example")!)
  let favoriteA = try #require(favoriteAID)
  let favoriteBID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://favorite-b.example")!)
  let favoriteB = try #require(favoriteBID)
  session.selectSpace(firstSpace)
  let fallbackID = session.open(URL(string: "https://fallback.example")!)!
  let nextFallbackID = session.open(URL(string: "https://next-fallback.example")!)!
  session.selectTab(fallbackID, in: firstSpace)
  session.selectSpace(secondSpace)
  let destinationFallbackID = session.open(URL(string: "https://destination-fallback.example")!)!
  let selectedB = session.selectFavorite(favoriteB, in: secondSpace)
  #expect(selectedB)
  session.selectSpace(firstSpace)
  let selectedA = session.selectFavorite(favoriteA, in: firstSpace)
  #expect(selectedA)
  #expect(session.selectedSpace.selectedTabID == fallbackID)

  let movedBackground = session.moveTab(fallbackID, from: firstSpace, to: secondSpace)
  #expect(movedBackground)
  #expect(session.selectedSpaceID == firstSpace)
  #expect(session.spaces.first { $0.id == firstSpace }?.selectedFavoriteID == favoriteA)
  #expect(session.spaces.first { $0.id == firstSpace }?.selectedTabID == nextFallbackID)
  #expect(session.spaces.first { $0.id == secondSpace }?.selectedFavoriteID == favoriteB)
  #expect(session.spaces.first { $0.id == secondSpace }?.selectedTabID == destinationFallbackID)

  session.selectOrdinaryTab(nextFallbackID, in: firstSpace)
  let movedSelected = session.moveTab(nextFallbackID, from: firstSpace, to: secondSpace)
  #expect(movedSelected)
  #expect(session.selectedSpaceID == secondSpace)
  #expect(session.spaces.first { $0.id == secondSpace }?.selectedFavoriteID == nil)
  #expect(session.selectedSpace.selectedTabID == nextFallbackID)
  try session.validate()
}

@Test func movingBackgroundFolderWhileFavoriteSelectedPreservesBothSpaceSelections() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let source = session.selectedSpaceID
  let destinationID = session.addSpace(name: "Shared", sharingProfile: profile)
  let destination = try #require(destinationID)
  let sourceFavoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://source.example")!)
  let sourceFavorite = try #require(sourceFavoriteID)
  let destinationFavoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://destination.example")!)
  let destinationFavorite = try #require(destinationFavoriteID)
  session.selectSpace(source)
  let folder = session.addFolder(name: "Pinned group", in: source)!
  let member = session.open(URL(string: "https://member.example")!)!
  let nested = session.moveTab(member, from: source, to: source, folderID: folder)
  #expect(nested)
  let fallback = session.open(URL(string: "https://fallback.example")!)!
  session.selectTab(member, in: source)
  let selectedDestination = session.selectFavorite(destinationFavorite, in: destination)
  #expect(selectedDestination)
  session.selectSpace(source)
  let selectedSource = session.selectFavorite(sourceFavorite, in: source)
  #expect(selectedSource)

  let moved = session.moveFolder(folder, from: source, to: destination)
  #expect(moved)
  #expect(session.selectedSpaceID == source)
  #expect(session.spaces.first { $0.id == source }?.selectedFavoriteID == sourceFavorite)
  #expect(session.spaces.first { $0.id == source }?.selectedTabID == fallback)
  #expect(session.spaces.first { $0.id == destination }?.selectedFavoriteID == destinationFavorite)
  try session.validate()
}

extension BrowserSelectedPage {
  fileprivate var favoritePage: BrowserFavoritePage? {
    guard case .favorite(let page) = self else { return nil }
    return page
  }
}
