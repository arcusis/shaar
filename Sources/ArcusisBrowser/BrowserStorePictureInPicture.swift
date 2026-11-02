// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Per-site automatic picture-in-picture, shared by playback and the site control center.
extension BrowserStore {
  /// On by default. Pages without a site (such as local files) are always allowed.
  func automaticPictureInPictureAllowed(for url: URL, profileID: UUID) -> Bool {
    guard let site = SiteSettingKey.site(for: url) else { return true }
    return preferences.allowsAutomaticPictureInPicture(on: site, for: profileID)
  }

  /// Saves the choice for the page's site and applies it to the profile's open pages.
  func setAutomaticPictureInPicture(_ allowed: Bool, for url: URL, profileID: UUID) {
    guard let site = SiteSettingKey.site(for: url) else { return }
    preferences.setAutomaticPictureInPicture(allowed, on: site, for: profileID)
    onAutomaticPictureInPictureChanged?(site, profileID)
  }

  /// Whether a live page may open picture-in-picture automatically.
  func automaticPictureInPictureAllowed(forTab tabID: UUID) -> Bool {
    guard let page = session.page(forTabID: tabID),
      let profileID = session.profileID(forTabID: tabID)
    else { return false }
    return automaticPictureInPictureAllowed(for: page.tab.url, profileID: profileID)
  }
}
