// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

extension BrowserStore {
  /// The live page icon, or the last icon saved for a pinned tab whose page has not loaded.
  func favicon(for tab: BrowserTab, profileID: UUID) -> NSImage? {
    if let live = engine?.favicons[tab.id] { return live }
    guard tab.isPinned, let pinID = sharedPinID?(tab.id) else { return nil }
    return faviconCache?.icon(for: pinID, profileID: profileID)
  }

  /// The live page icon, or the last icon saved for the Favorite.
  func favicon(for favorite: BrowserFavorite) -> NSImage? {
    if let page = session.favoritePage(for: favorite.id),
      let live = engine?.favicons[page.tab.id]
    {
      return live
    }
    return faviconCache?.icon(for: favorite.id, profileID: favorite.profileID)
  }

  /// The icon for any page by its tab: live, or saved for its Favorite or pinned tab.
  func favicon(forPage tabID: UUID) -> NSImage? {
    switch session.page(forTabID: tabID) {
    case .tab(let tab):
      guard let profileID = session.profileID(forTabID: tabID) else { return nil }
      return favicon(for: tab, profileID: profileID)
    case .favorite(let page):
      guard let favorite = session.favorites.first(where: { $0.id == page.favoriteID }) else {
        return nil
      }
      return favicon(for: favorite)
    case nil:
      return nil
    }
  }

  /// Saves a page icon reported by the engine when the page is a Favorite or a pinned tab.
  func rememberFavicon(_ image: NSImage, forTab tabID: UUID) {
    guard let itemID = faviconItemID(forTab: tabID),
      let profileID = session.profileID(forTabID: tabID)
    else { return }
    faviconCache?.store(image, for: itemID, profileID: profileID)
  }

  private func faviconItemID(forTab tabID: UUID) -> UUID? {
    switch session.page(forTabID: tabID) {
    case .favorite(let page): page.favoriteID
    case .tab(let tab) where tab.isPinned: sharedPinID?(tab.id)
    default: nil
    }
  }
}
