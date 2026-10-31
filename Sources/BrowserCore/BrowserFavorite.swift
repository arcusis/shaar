// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Shared Favorite address and display metadata. Live navigation belongs to each window.
public struct BrowserFavorite: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let profileID: UUID
  public var originalURL: URL
  public var title: String

  public init(
    id: UUID = UUID(), profileID: UUID, originalURL: URL, title: String? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.originalURL = originalURL
    self.title = title ?? originalURL.host() ?? originalURL.absoluteString
  }
}

/// Window-local page identity and current navigation for one shared Favorite.
public struct BrowserFavoritePage: Codable, Equatable, Sendable {
  public let favoriteID: UUID
  public var tab: BrowserTab

  public init(favoriteID: UUID, tab: BrowserTab) {
    self.favoriteID = favoriteID
    self.tab = tab
  }
}

public enum FavoritePageDisposition: Sendable {
  case preserveAsTab
  case closePage
}

public enum BrowserSelectedPage: Equatable, Sendable {
  case tab(BrowserTab)
  case favorite(BrowserFavoritePage)

  public var tab: BrowserTab {
    switch self {
    case .tab(let tab): tab
    case .favorite(let page): page.tab
    }
  }
}
