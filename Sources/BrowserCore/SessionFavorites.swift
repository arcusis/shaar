import Foundation

extension BrowserSession {
  public static let maximumFavoritesPerProfile = 16

  public var selectedFavorite: BrowserFavorite? {
    guard let id = selectedSpace.selectedFavoriteID else { return nil }
    return favorites.first { $0.id == id }
  }

  public var selectedFavoritePage: BrowserFavoritePage? {
    guard let id = selectedSpace.selectedFavoriteID else { return nil }
    return favoritePages.first { $0.favoriteID == id }
  }

  /// Favorite selection takes precedence; ordinary tab selection remains stored as fallback.
  public var selectedPage: BrowserSelectedPage? {
    if let page = selectedFavoritePage { return .favorite(page) }
    return selectedSpace.selectedTab.flatMap { .tab($0) }
  }

  public func favorites(for profileID: UUID) -> [BrowserFavorite] {
    favorites.filter { $0.profileID == profileID }
  }

  public func page(forTabID tabID: UUID) -> BrowserSelectedPage? {
    if let tab = spaces.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }) {
      return .tab(tab)
    }
    guard let page = favoritePages.first(where: { $0.tab.id == tabID }) else { return nil }
    return .favorite(page)
  }

  public func profileID(forTabID tabID: UUID) -> UUID? {
    if let space = spaces.first(where: { $0.tabs.contains(where: { $0.id == tabID }) }) {
      return space.profileID
    }
    guard let page = favoritePages.first(where: { $0.tab.id == tabID }) else { return nil }
    return favorites.first(where: { $0.id == page.favoriteID })?.profileID
  }

  @discardableResult
  public mutating func addFavorite(
    profileID: UUID, originalURL: URL, title: String? = nil, id: UUID = UUID()
  ) -> UUID? {
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard favorites(for: profileID).count < Self.maximumFavoritesPerProfile,
      profiles.contains(where: { $0.id == profileID }),
      spaces.contains(where: { $0.profileID == profileID }),
      Self.isPersistableURL(originalURL), cleanTitle.map({ !$0.isEmpty }) ?? true,
      !favorites.contains(where: { $0.id == id })
    else { return nil }
    favorites.append(
      BrowserFavorite(id: id, profileID: profileID, originalURL: originalURL, title: cleanTitle))
    let favorite = favorites[favorites.count - 1]
    favoritePages.append(
      BrowserFavoritePage(
        favoriteID: id, tab: BrowserTab(url: favorite.originalURL, title: favorite.title)))
    return id
  }

  @discardableResult
  public mutating func promoteTabToFavorite(_ tabID: UUID, in spaceID: UUID) -> UUID? {
    guard let spaceIndex = spaces.firstIndex(where: { $0.id == spaceID }),
      let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: { $0.id == tabID })
    else { return nil }
    guard favorites(for: spaces[spaceIndex].profileID).count < Self.maximumFavoritesPerProfile
    else {
      return nil
    }
    let source = spaces[spaceIndex].tabs[tabIndex]
    guard !favorites.contains(where: { $0.id == tabID }) else { return nil }
    let favoriteID = UUID()
    let cleanTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = cleanTitle.isEmpty ? source.url.host() ?? source.url.absoluteString : source.title
    var tab = source
    tab.title = title
    tab.isPinned = false
    tab.folderID = nil

    spaces[spaceIndex].tabs.remove(at: tabIndex)
    spaces[spaceIndex].reconcileSplits()
    if spaces[spaceIndex].selectedTabID == tabID {
      let ordinary = spaces[spaceIndex].tabs.filter { !$0.isPinned }
      spaces[spaceIndex].selectedTabID = ordinary.first?.id
    }
    favorites.append(
      BrowserFavorite(
        id: favoriteID, profileID: spaces[spaceIndex].profileID,
        originalURL: source.url, title: title))
    favoritePages.append(BrowserFavoritePage(favoriteID: favoriteID, tab: tab))
    selectedSpaceID = spaceID
    spaces[spaceIndex].selectedFavoriteID = favoriteID
    return favoriteID
  }

  @discardableResult
  public mutating func selectFavorite(_ id: UUID, in spaceID: UUID) -> Bool {
    guard let space = spaces.first(where: { $0.id == spaceID }),
      let favorite = favorites.first(where: { $0.id == id && $0.profileID == space.profileID })
    else { return false }
    if !favoritePages.contains(where: { $0.favoriteID == id }) {
      favoritePages.append(
        BrowserFavoritePage(
          favoriteID: id, tab: BrowserTab(url: favorite.originalURL, title: favorite.title)))
    }
    selectedSpaceID = spaceID
    if let index = spaces.firstIndex(where: { $0.id == spaceID }) {
      spaces[index].selectedFavoriteID = favorite.id
    }
    return true
  }

  @discardableResult
  public mutating func openFavorite(_ id: UUID) -> UUID? {
    guard let favorite = favorites.first(where: { $0.id == id }),
      let space = spaces.first(where: { $0.profileID == favorite.profileID })
    else { return nil }
    let destination = selectedSpace.profileID == favorite.profileID ? selectedSpaceID : space.id
    guard selectFavorite(id, in: destination) else { return nil }
    return favoritePages.first(where: { $0.favoriteID == id })?.tab.id
  }

  @discardableResult
  public mutating func updateFavoritePage(
    _ favoriteID: UUID, url: URL, title: String
  ) -> Bool {
    guard Self.isPersistableURL(url),
      let index = favoritePages.firstIndex(where: { $0.favoriteID == favoriteID })
    else { return false }
    let providedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanTitle = providedTitle.isEmpty ? url.host() ?? url.absoluteString : providedTitle
    guard favoritePages[index].tab.url != url || favoritePages[index].tab.title != cleanTitle else {
      return false
    }
    favoritePages[index].tab.url = url
    favoritePages[index].tab.title = cleanTitle
    return true
  }

  @discardableResult
  public mutating func closeFavoritePage(_ favoriteID: UUID) -> Bool {
    guard favoritePages.contains(where: { $0.favoriteID == favoriteID }) else { return false }
    favoritePages.removeAll { $0.favoriteID == favoriteID }
    for index in spaces.indices where spaces[index].selectedFavoriteID == favoriteID {
      spaces[index].selectedFavoriteID = nil
    }
    return true
  }

  @discardableResult
  public mutating func removeFavorite(
    _ favoriteID: UUID, disposition: FavoritePageDisposition
  ) -> Bool {
    guard let definition = favorites.first(where: { $0.id == favoriteID }) else { return false }
    if let page = favoritePages.first(where: { $0.favoriteID == favoriteID }) {
      switch disposition {
      case .closePage:
        _ = closeFavoritePage(favoriteID)
      case .preserveAsTab:
        guard
          let fallbackDestination = spaces.firstIndex(where: {
            $0.profileID == definition.profileID
          })
        else {
          return false
        }
        let selectedPage = spaces.contains {
          $0.id == selectedSpaceID && $0.selectedFavoriteID == favoriteID
        }
        let destination =
          spaces.firstIndex(where: {
            $0.profileID == definition.profileID && $0.id == selectedSpaceID
          }) ?? spaces.firstIndex(where: {
            $0.profileID == definition.profileID && $0.selectedFavoriteID == favoriteID
          }) ?? fallbackDestination
        var tab = page.tab
        tab.isPinned = false
        tab.folderID = nil
        spaces[destination].tabs.append(tab)
        spaces[destination].selectedTabID = tab.id
        if selectedPage { selectedSpaceID = spaces[destination].id }
        _ = closeFavoritePage(favoriteID)
      }
    }
    favorites.removeAll { $0.id == favoriteID }
    for index in spaces.indices where spaces[index].selectedFavoriteID == favoriteID {
      spaces[index].selectedFavoriteID = nil
    }
    return true
  }

  @discardableResult
  public mutating func moveFavorite(
    _ id: UUID, in profileID: UUID, before targetID: UUID? = nil
  ) -> Bool {
    guard let source = favorites.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
      id != targetID,
      targetID == nil
        || favorites.contains(where: { $0.id == targetID && $0.profileID == profileID })
    else { return false }
    var reordered = favorites
    let favorite = reordered.remove(at: source)
    let destination =
      targetID.flatMap { target in
        reordered.firstIndex { $0.id == target }
      } ?? reordered.lastIndex(where: { $0.profileID == profileID }).map { $0 + 1 }
      ?? reordered.endIndex
    reordered.insert(favorite, at: destination)
    guard reordered != favorites else { return false }
    favorites = reordered
    return true
  }

  public mutating func selectOrdinaryTab(_ tabID: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].tabs.contains(where: { $0.id == tabID })
    else { return }
    spaces[index].selectedFavoriteID = nil
    selectTab(tabID, in: spaceID)
  }
}
