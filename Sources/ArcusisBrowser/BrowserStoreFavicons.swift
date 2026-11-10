// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

extension BrowserStore {
  /// The live page icon, or the last icon saved for a tab whose page has not loaded.
  /// Private windows show the live icon and never the on-disk cache.
  func favicon(for tab: BrowserTab, profileID: UUID) -> NSImage? {
    if let live = engine?.favicons[tab.id] { return live }
    if isPrivate { return nil }
    guard let itemID = faviconItemID(forTab: tab.id) else { return nil }
    return faviconCache?.icon(for: itemID, profileID: profileID)
  }

  /// The live page icon, or the last icon saved for the Favorite.
  /// Private windows show the live icon and never the on-disk cache.
  func favicon(for favorite: BrowserFavorite) -> NSImage? {
    if let page = session.favoritePage(for: favorite.id),
      let live = engine?.favicons[page.tab.id]
    {
      return live
    }
    if isPrivate { return nil }
    return faviconCache?.icon(for: favorite.id, profileID: favorite.profileID)
  }

  /// The icon for any page by its tab: live, or saved for its Favorite or tab.
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

  /// Saves a page icon for a pinned tab or Favorite.
  /// Ordinary tabs and private windows show the live icon and do not write a file.
  func rememberFavicon(_ image: NSImage, forTab tabID: UUID, host: String? = nil) {
    guard !isPrivate, remembersFavicon(forTab: tabID) else { return }
    guard let itemID = faviconItemID(forTab: tabID),
      let profileID = session.profileID(forTabID: tabID)
    else { return }
    faviconCache?.store(image, for: itemID, profileID: profileID, host: host)
  }

  /// The site host stored beside a pinned tab or Favorite icon.
  func faviconHost(forTab tabID: UUID) -> String? {
    guard !isPrivate else { return nil }
    guard let itemID = faviconItemID(forTab: tabID),
      let profileID = session.profileID(forTabID: tabID)
    else { return nil }
    return faviconCache?.host(for: itemID, profileID: profileID)
  }

  /// Drops the saved icon after the page moves to a site that has none.
  func forgetFavicon(forTab tabID: UUID) {
    guard !isPrivate else { return }
    guard let itemID = faviconItemID(forTab: tabID),
      let profileID = session.profileID(forTabID: tabID)
    else { return }
    faviconCache?.remove(itemID, profileID: profileID)
  }

  func remembersFavicon(forTab tabID: UUID) -> Bool {
    switch session.page(forTabID: tabID) {
    case .favorite: true
    case .tab(let tab): tab.isPinned
    default: false
    }
  }

  /// Writes an icon captured before a pin or Favorite change onto the new cache key.
  /// Ordinary tabs are not persisted. The copy happens after the save that drops the old key.
  func carryFavicon(_ image: NSImage?, toTab tabID: UUID) {
    guard let image, remembersFavicon(forTab: tabID) else { return }
    rememberFavicon(image, forTab: tabID, host: faviconHost(forTab: tabID) ?? pageHost(for: tabID))
  }

  private func pageHost(for tabID: UUID) -> String? {
    switch session.page(forTabID: tabID) {
    case .tab(let tab): tab.url.host?.lowercased()
    case .favorite(let page): page.tab.url.host?.lowercased()
    case nil: nil
    }
  }

  private func faviconItemID(forTab tabID: UUID) -> UUID? {
    switch session.page(forTabID: tabID) {
    case .favorite(let page): page.favoriteID
    case .tab(let tab): tab.isPinned ? (sharedPinID?(tab.id) ?? tab.id) : tab.id
    default: nil
    }
  }
}
