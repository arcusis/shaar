import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FavoriteSelectedPageTests {
  @Test func bookmarkUsesFavoriteLiveURLAndTitleWithoutChangingDefinition() throws {
    let initialURL = URL(string: "https://favorite.example/saved")!
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    let addedFavoriteID = session.addFavorite(
      profileID: profileID, originalURL: initialURL, title: "Saved title")
    let favoriteID = try #require(addedFavoriteID)
    let pageID = try #require(session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id)
    let updated = session.updateFavoritePage(
      favoriteID, url: URL(string: "https://favorite.example/current")!, title: "Current title")
    #expect(updated)
    let selected = session.selectFavorite(favoriteID, in: session.selectedSpaceID)
    #expect(selected)
    let store = BrowserStore(session: session)
    let originalDefinition = try #require(store.session.favorites.first { $0.id == favoriteID })
    let selectedPage = try #require(store.session.selectedPage)

    #expect(selectedPage.tab.id == pageID)
    #expect(store.canBookmarkCurrentPage)
    store.bookmarkCurrentPage()
    guard case .bookmarkEditor(let route)? = store.sheet,
      case .newBookmark(_, let title, let address) = route.mode
    else {
      Issue.record("Bookmark route must use selected Favorite page")
      return
    }
    #expect(title == "Current title")
    #expect(address == "https://favorite.example/current")
    #expect(store.session.favorites.first { $0.id == favoriteID } == originalDefinition)
  }

  @Test func findAndRendererFailureBelongToLiveFavoritePageAndProfile() throws {
    let favoriteURL = URL(string: "https://favorite.example/current")!
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    let addedFavoriteID = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example/start")!)
    let favoriteID = try #require(addedFavoriteID)
    let pageID = try #require(session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id)
    let updated = session.updateFavoritePage(favoriteID, url: favoriteURL, title: "Current")
    #expect(updated)
    let selected = session.selectFavorite(favoriteID, in: session.selectedSpaceID)
    #expect(selected)
    let state = PageFindState(profileID: profileID, tabID: pageID, pageURL: favoriteURL)
    let failure = RendererFailure(
      profileID: profileID, tabID: pageID, pageURL: favoriteURL,
      status: "crashed", exitCode: 1)

    #expect(state.matches(session))
    #expect(failure.belongs(to: session))

    let wrongID = PageFindState(profileID: profileID, tabID: UUID(), pageURL: favoriteURL)
    let wrongURL = PageFindState(
      profileID: profileID, tabID: pageID, pageURL: URL(string: "https://other.example")!)
    let wrongProfile = RendererFailure(
      profileID: UUID(), tabID: pageID, pageURL: favoriteURL,
      status: "crashed", exitCode: 1)
    #expect(!wrongID.matches(session))
    #expect(!wrongURL.matches(session))
    #expect(!wrongProfile.belongs(to: session))

    let closed = session.closeFavoritePage(favoriteID)
    #expect(closed)
    #expect(!state.matches(session))
    #expect(!failure.belongs(to: session))
  }

  @Test func selectedFavoriteDoesNotFallBackToOrdinaryTabForBookmark() throws {
    let ordinaryURL = URL(string: "https://ordinary.example/page")!
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    let ordinaryID = session.open(ordinaryURL)
    #expect(ordinaryID != nil)
    let addedFavoriteID = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example")!)
    let favoriteID = try #require(addedFavoriteID)
    let selected = session.selectFavorite(favoriteID, in: session.selectedSpaceID)
    #expect(selected)
    let store = BrowserStore(session: session)
    #expect(store.session.selectedPage?.tab.url.absoluteString == "https://favorite.example")
    #expect(store.canBookmarkCurrentPage)
    store.bookmarkCurrentPage()
    guard case .bookmarkEditor(let route)? = store.sheet,
      case .newBookmark(_, _, let address) = route.mode
    else {
      Issue.record("Bookmark action must remain bound to selected Favorite")
      return
    }
    #expect(address == "https://favorite.example")
    #expect(address != ordinaryURL.absoluteString)
  }
}
