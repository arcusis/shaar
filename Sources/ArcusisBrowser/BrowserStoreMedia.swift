// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

/// The page the sidebar player controls.
struct MiniPlayerItem {
  let tabID: UUID
  let pageTitle: String
  let favicon: NSImage?
  let state: MediaSessionState
}

extension BrowserStore {
  /// Pages on screen in this window: the selected page and the rest of its split.
  var visiblePageIDs: Set<UUID> {
    var visible = Set(selectedSplit?.tabIDs ?? [])
    if let selected = session.selectedPage?.tab.id { visible.insert(selected) }
    return visible
  }

  /// The Space that shows a page: a tab's own Space; for a Favorite page the selected Space
  /// when it uses the Favorite's profile, otherwise the first Space with that profile.
  func spaceID(showingPage tabID: UUID) -> UUID? {
    if let space = session.spaces.first(where: { $0.tabs.contains { $0.id == tabID } }) {
      return space.id
    }
    guard let profileID = session.profileID(forTabID: tabID) else { return nil }
    if session.selectedSpace.profileID == profileID { return session.selectedSpaceID }
    return session.spaces.first { $0.profileID == profileID }?.id
  }

  /// Selects a page wherever it lives, switching Space when needed.
  func selectPage(_ tabID: UUID) {
    guard let spaceID = spaceID(showingPage: tabID) else { return }
    perform(.tab(space: spaceID, tab: tabID))
  }

  var miniPlayerItem: MiniPlayerItem? {
    guard let tabID = media.miniPlayerTabID(hiding: visiblePageIDs),
      let state = media.sessions[tabID], let page = session.page(forTabID: tabID)
    else { return nil }
    return MiniPlayerItem(
      tabID: tabID, pageTitle: page.tab.title, favicon: engine?.favicons[tabID], state: state)
  }

  @discardableResult
  func performMedia(_ command: MediaCommand, tabID: UUID) -> Bool {
    onMediaCommand?(tabID, command) ?? false
  }
}
