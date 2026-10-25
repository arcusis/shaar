import Foundation
import Testing

@testable import BrowserCore

@Test func sharedProfileFavoritesKeepWindowLocalPagesAcrossSpacesAndWindows() throws {
  var session = BrowserSession.fresh()
  let sharedProfile = session.selectedSpace.profileID
  let firstSpace = session.selectedSpaceID
  let sharedSpaceID = session.addSpace(name: "Shared work", sharingProfile: sharedProfile)
  let sharedSpace = try #require(sharedSpaceID)
  let isolatedSpaceID = session.addSpace(name: "Separate account")
  let isolatedSpace = try #require(isolatedSpaceID)
  let isolatedProfile = try #require(session.spaces.first { $0.id == isolatedSpace }?.profileID)
  let mailID = session.addFavorite(
    profileID: sharedProfile, originalURL: URL(string: "https://mail.example.com")!, title: "Mail")
  let mail = try #require(mailID)
  let videoID = session.addFavorite(
    profileID: sharedProfile, originalURL: URL(string: "https://video.example.com")!, title: "Video"
  )
  let video = try #require(videoID)
  let isolatedID = session.addFavorite(
    profileID: isolatedProfile, originalURL: URL(string: "https://private.example.net")!,
    title: "Private")
  let isolated = try #require(isolatedID)
  var workspace = try BrowserWorkspace(session: session)
  let firstWindow = workspace.windows[0].id
  let secondWindow = try workspace.addWindow(from: firstWindow)
  let firstPages = workspace.window(firstWindow)!.session.favoritePages
  let secondPages = workspace.window(secondWindow)!.session.favoritePages
  #expect(firstPages.count == 3 && secondPages.count == 3)
  #expect(Set(firstPages.map(\.tab.id)).isDisjoint(with: Set(secondPages.map(\.tab.id))))

  let mailPageID = try #require(firstPages.first { $0.favoriteID == mail }?.tab.id)
  let videoPageID = try #require(firstPages.first { $0.favoriteID == video }?.tab.id)
  #expect(mailPageID != videoPageID)
  let updated = try workspace.updateFavoritePage(
    windowID: firstWindow, favoriteID: mail, url: URL(string: "https://mail.example.com/inbox")!,
    title: "Inbox")
  #expect(updated)
  #expect(
    workspace.catalog.favorites.first { $0.id == mail }?.originalURL.absoluteString
      == "https://mail.example.com")
  #expect(
    workspace.window(secondWindow)!.session.favoritePages.first { $0.favoriteID == mail }?.tab.url
      .absoluteString
      == "https://mail.example.com")
  #expect(
    workspace.window(firstWindow)!.session.favoritePages.first { $0.favoriteID == video }?.tab.id
      == videoPageID)

  var first = workspace.window(firstWindow)!.session
  first.selectSpace(firstSpace)
  let ordinary = first.open(URL(string: "https://ordinary.example")!)!
  first.selectOrdinaryTab(ordinary, in: firstSpace)
  try workspace.updateWindow(firstWindow, session: first)
  let selectedMail = try workspace.selectFavorite(
    windowID: firstWindow, favoriteID: mail, in: firstSpace)
  #expect(selectedMail)
  #expect(workspace.window(firstWindow)!.session.selectedSpace.selectedTabID == ordinary)
  #expect(workspace.window(firstWindow)!.session.selectedPage?.favoritePage?.favoriteID == mail)
  let selectedVideo = try workspace.selectFavorite(
    windowID: firstWindow, favoriteID: video, in: sharedSpace)
  #expect(selectedVideo)
  #expect(workspace.window(firstWindow)!.session.selectedPage?.favoritePage?.favoriteID == video)
  try workspace.focusWindow(secondWindow)
  let selectedIsolated = try workspace.selectFavorite(
    windowID: secondWindow, favoriteID: isolated, in: isolatedSpace)
  #expect(selectedIsolated)
  #expect(workspace.window(firstWindow)!.session.selectedPage?.favoritePage?.favoriteID == video)
  try workspace.validate()
}

@Test func sharedFavoriteRemovalPreservesRemoteLivePageAsOrdinaryTab() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://example.com/start")!)
  let favorite = try #require(favoriteID)
  var workspace = try BrowserWorkspace(session: session)
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let remotePage = try #require(workspace.window(second)!.session.favoritePages.first)
  let updated = try workspace.updateFavoritePage(
    windowID: second, favoriteID: favorite, url: URL(string: "https://example.com/current")!,
    title: "Current")
  #expect(updated)
  let removed = try workspace.removeFavorite(
    windowID: first, favoriteID: favorite, disposition: .closePage)
  #expect(removed)
  #expect(workspace.catalog.favorites.isEmpty)
  #expect(workspace.window(first)!.session.favoritePages.isEmpty)
  let retained = try #require(
    workspace.window(second)!.session.spaces[0].tabs.first { $0.id == remotePage.tab.id })
  #expect(!retained.isPinned && retained.url.absoluteString == "https://example.com/current")
  #expect(workspace.window(second)!.session.favoritePages.isEmpty)
  try workspace.validate()
}

@Test func closingPageKeepsSharedDefinitionAndOtherWindowPage() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://example.org")!)
  let favorite = try #require(favoriteID)
  var workspace = try BrowserWorkspace(session: session)
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let firstPage = try #require(workspace.window(first)!.session.favoritePages.first)
  let secondPage = try #require(workspace.window(second)!.session.favoritePages.first)
  let closed = try workspace.closeFavoritePage(windowID: first, favoriteID: favorite)
  #expect(closed)
  #expect(workspace.catalog.favorites.count == 1)
  #expect(workspace.window(first)!.session.favoritePages.isEmpty)
  #expect(workspace.window(second)!.session.favoritePages.first == secondPage)
  #expect(firstPage.tab.id != secondPage.tab.id)
  let reopened = try workspace.selectFavorite(
    windowID: first, favoriteID: favorite, in: session.selectedSpaceID)
  #expect(reopened)
  let reopenedPage = try #require(workspace.window(first)!.session.favoritePages.first)
  #expect(reopenedPage.tab.id != firstPage.tab.id)
  #expect(reopenedPage.tab.url.absoluteString == "https://example.org")
  try workspace.validate()
}

@Test func removingLastReachableSpaceClosesPagesExplicitlyButRetainsFavoriteDefinitions() throws {
  var session = BrowserSession.fresh()
  let remove = session.selectedSpaceID
  let favoriteProfile = session.selectedSpace.profileID
  let favoriteID = session.addFavorite(
    profileID: favoriteProfile, originalURL: URL(string: "https://account.example")!)
  let favorite = try #require(favoriteID)
  let remaining = session.spaces[1].id
  var workspace = try BrowserWorkspace(session: session)
  let window = workspace.windows[0].id
  let secondWindow = try workspace.addWindow(from: window)
  let rejectedPreserve = try workspace.removeSpace(
    remove, windowID: window, favoriteDisposition: .preserveAsTab)
  #expect(!rejectedPreserve)
  let removed = try workspace.removeSpace(
    remove, windowID: window, favoriteDisposition: .closePage)
  #expect(removed)
  #expect(workspace.catalog.spaces.map(\.id) == [remaining])
  #expect(workspace.catalog.favorites.first?.id == favorite)
  #expect(workspace.window(window)!.session.favoritePages.isEmpty)
  #expect(workspace.window(secondWindow)!.session.favoritePages.isEmpty)
  #expect(workspace.window(window)!.session.favorites.first?.id == favorite)
  try workspace.validate()
}

@Test func preservedFavoriteStaysInActiveSharedSpaceLocallyAndRemotely() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let firstSpace = session.selectedSpaceID
  let secondSpaceID = session.addSpace(name: "Shared account", sharingProfile: profile)
  let secondSpace = try #require(secondSpaceID)
  let favoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://account.example/start")!)
  let favorite = try #require(favoriteID)
  var workspace = try BrowserWorkspace(session: session)
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let selectedFirst = try workspace.selectFavorite(
    windowID: first, favoriteID: favorite, in: secondSpace)
  #expect(selectedFirst)
  let selectedSecond = try workspace.selectFavorite(
    windowID: second, favoriteID: favorite, in: secondSpace)
  #expect(selectedSecond)
  let updated = try workspace.updateFavoritePage(
    windowID: second, favoriteID: favorite,
    url: URL(string: "https://account.example/current")!, title: "Current")
  #expect(updated)
  let removed = try workspace.removeFavorite(
    windowID: first, favoriteID: favorite, disposition: .preserveAsTab)
  #expect(removed)
  #expect(workspace.window(first)!.session.selectedSpaceID == secondSpace)
  #expect(workspace.window(second)!.session.selectedSpaceID == secondSpace)
  #expect(
    workspace.window(first)!.session.spaces.first { $0.id == firstSpace }?.tabs.isEmpty == true)
  #expect(
    workspace.window(first)!.session.selectedSpace.selectedTab?.url.absoluteString
      == "https://account.example/start")
  #expect(
    workspace.window(second)!.session.selectedSpace.selectedTab?.url.absoluteString
      == "https://account.example/current")
  try workspace.validate()
}

@Test func catalogChangesProjectWhilePeerWindowHasFavoriteSelected() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let spaceID = session.selectedSpaceID
  let favoriteID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://one.example")!)
  let favorite = try #require(favoriteID)
  var workspace = try BrowserWorkspace(session: session)
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let selected = try workspace.selectFavorite(windowID: second, favoriteID: favorite, in: spaceID)
  #expect(selected)

  var firstSession = workspace.window(first)!.session
  let renamed = firstSession.updateSpace(spaceID, name: "Renamed", tint: .forest)
  #expect(renamed)
  try workspace.updateWindow(first, session: firstSession)
  #expect(workspace.window(second)!.session.selectedFavorite?.id == favorite)
  #expect(workspace.window(second)!.session.selectedSpace.name == "Renamed")

  let addedID = try workspace.addFavorite(
    windowID: first, profileID: profile, originalURL: URL(string: "https://two.example")!)
  let added = try #require(addedID)
  #expect(workspace.window(second)!.session.selectedFavorite?.id == favorite)
  let firstPage = try #require(
    workspace.window(first)!.session.favoritePages.first { $0.favoriteID == added })
  let secondPage = try #require(
    workspace.window(second)!.session.favoritePages.first { $0.favoriteID == added })
  #expect(firstPage.tab.id != secondPage.tab.id)

  let moved = try workspace.moveFavorite(
    windowID: first, favoriteID: added, in: profile, before: favorite)
  #expect(moved)
  #expect(
    workspace.catalog.favorites.filter { $0.profileID == profile }.map(\.id)
      == [added, favorite])
  #expect(workspace.window(second)!.session.selectedFavorite?.id == favorite)
  #expect(workspace.window(second)!.session.favoritePages.count == 2)
  try workspace.validate()
}

@Test func tabPromotionPreservesLocalIdentityAndPeerPinPage() throws {
  var session = BrowserSession.fresh()
  let spaceID = session.selectedSpaceID
  let profile = session.selectedSpace.profileID
  let existingID = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://existing.example")!)
  let existing = try #require(existingID)
  let promotedTabID = session.open(URL(string: "https://promote.example/current")!)!
  session.togglePin(promotedTabID)
  let folder = session.addFolder(name: "Pinned", in: spaceID)!
  _ = session.moveTab(promotedTabID, from: spaceID, to: spaceID, folderID: folder)
  let fallback = session.open(URL(string: "https://fallback.example")!)!
  session.selectTab(promotedTabID, in: spaceID)
  var workspace = try BrowserWorkspace(session: session)
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let selected = try workspace.selectFavorite(windowID: second, favoriteID: existing, in: spaceID)
  #expect(selected)
  let peerPinID = try #require(
    workspace.window(second)!.session.spaces.first { $0.id == spaceID }?.tabs.first {
      $0.isPinned && $0.url.host() == "promote.example"
    }?.id)

  var origin = workspace.window(first)!.session
  let promotedID = origin.promoteTabToFavorite(promotedTabID, in: spaceID)
  let newFavorite = try #require(promotedID)
  try workspace.updateWindow(first, session: origin)
  #expect(newFavorite != existing)
  #expect(workspace.catalog.spaces.first { $0.id == spaceID }?.tabs.isEmpty == true)
  let localPage = try #require(
    workspace.window(first)!.session.favoritePages.first { $0.favoriteID == newFavorite })
  #expect(localPage.tab.id == promotedTabID)
  #expect(workspace.window(first)!.session.selectedSpace.selectedTabID == fallback)
  #expect(workspace.window(first)!.session.selectedPage?.favoritePage?.favoriteID == newFavorite)
  let peer = workspace.window(second)!.session
  #expect(peer.selectedFavorite?.id == existing)
  #expect(
    peer.favoritePages.contains { $0.favoriteID == newFavorite && $0.tab.id != promotedTabID })
  #expect(
    peer.spaces.first { $0.id == spaceID }?.tabs.contains {
      $0.id == peerPinID && !$0.isPinned && $0.folderID == nil
    } == true)
  try workspace.validate()
}

@Test func workspaceV1MigrationRetainsBytesAndV2RejectsMissingModernFavoriteState() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let added = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://example.com")!)
  #expect(added != nil)
  let workspace = try BrowserWorkspace(session: session)
  var wire =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
  wire["version"] = 1
  var catalog = wire["catalog"] as! [String: Any]
  catalog.removeValue(forKey: "favorites")
  wire["catalog"] = catalog
  var windows = wire["windows"] as! [[String: Any]]
  windows = windows.map { source in
    var window = source
    var storedSession = window["session"] as! [String: Any]
    storedSession["version"] = 3
    storedSession.removeValue(forKey: "favorites")
    storedSession.removeValue(forKey: "favoritePages")
    var spaces = storedSession["spaces"] as! [[String: Any]]
    spaces = spaces.map { sourceSpace in
      var space = sourceSpace
      space.removeValue(forKey: "selectedFavoriteID")
      return space
    }
    storedSession["spaces"] = spaces
    window["session"] = storedSession
    return window
  }
  wire["windows"] = windows
  let bytes = try JSONSerialization.data(withJSONObject: wire)
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = WorkspaceFile(
    url: directory.appending(path: "workspace.json"),
    legacySessionURL: directory.appending(path: "session.json"))
  try bytes.write(to: file.url)
  let restored = try #require(try file.load())
  #expect(restored.version == 2)
  #expect(restored.catalog.favorites.isEmpty)
  #expect(restored.windows[0].session.version == 4)
  #expect(try Data(contentsOf: file.url) == bytes)

  var corruptLegacy = wire
  var corruptCatalog = corruptLegacy["catalog"] as! [String: Any]
  corruptCatalog["favorites"] = []
  corruptLegacy["catalog"] = corruptCatalog
  let corruptLegacyBytes = try JSONSerialization.data(withJSONObject: corruptLegacy)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(BrowserWorkspace.self, from: corruptLegacyBytes)
  }

  var malformed =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
  var modernCatalog = malformed["catalog"] as! [String: Any]
  modernCatalog.removeValue(forKey: "favorites")
  malformed["catalog"] = modernCatalog
  let invalid = try JSONSerialization.data(withJSONObject: malformed)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(BrowserWorkspace.self, from: invalid)
  }
  var future = malformed
  future["version"] = 99
  #expect(throws: WorkspaceError.self) {
    try JSONDecoder().decode(
      BrowserWorkspace.self, from: JSONSerialization.data(withJSONObject: future))
  }
}

@Test func staleAndForeignFavoriteActionsDoNotMutateWorkspace() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let window = workspace.windows[0].id
  let before = workspace
  let staleOpen = try workspace.openFavorite(windowID: window, favoriteID: UUID())
  #expect(staleOpen == nil)
  var rejectedForeignWindow = false
  do {
    _ = try workspace.selectFavorite(windowID: UUID(), favoriteID: UUID(), in: UUID())
  } catch WorkspaceError.unknownWindow {
    rejectedForeignWindow = true
  }
  #expect(rejectedForeignWindow)
  #expect(workspace == before)
}

@Test func existingFavoriteCannotChangeProfileOwnerAfterOriginPageClosed() throws {
  var session = BrowserSession.fresh()
  let firstProfile = session.selectedSpace.profileID
  let secondSpaceIDValue = session.addSpace(name: "Private account")
  let secondSpaceID = try #require(secondSpaceIDValue)
  let secondProfile = try #require(session.spaces.first { $0.id == secondSpaceID }?.profileID)
  let favoriteIDValue = session.addFavorite(
    profileID: firstProfile, originalURL: URL(string: "https://owner.example")!)
  let favoriteID = try #require(favoriteIDValue)
  var workspace = try BrowserWorkspace(session: session)
  let origin = workspace.windows[0].id
  let peer = try workspace.addWindow(from: origin)
  let peerPageID = try #require(
    workspace.window(peer)?.session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id)
  let closed = try workspace.closeFavoritePage(windowID: origin, favoriteID: favoriteID)
  #expect(closed)

  var wire =
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(workspace.window(origin)!.session)) as! [String: Any]
  var favorites = wire["favorites"] as! [[String: Any]]
  favorites[0]["profileID"] = secondProfile.uuidString
  wire["favorites"] = favorites
  let reassigned = try JSONDecoder().decode(
    BrowserSession.self, from: JSONSerialization.data(withJSONObject: wire))
  let beforeRejectedUpdate = workspace
  var rejected = false
  do {
    try workspace.updateWindow(origin, session: reassigned)
  } catch WorkspaceError.invalidState {
    rejected = true
  }
  #expect(rejected)
  #expect(workspace == beforeRejectedUpdate)
  #expect(workspace.window(peer)?.session.profileID(forTabID: peerPageID) == firstProfile)
  #expect(
    workspace.window(peer)?.session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id
      == peerPageID)
  try workspace.validate()
}

extension BrowserSelectedPage {
  fileprivate var favoritePage: BrowserFavoritePage? {
    guard case .favorite(let page) = self else { return nil }
    return page
  }
}
