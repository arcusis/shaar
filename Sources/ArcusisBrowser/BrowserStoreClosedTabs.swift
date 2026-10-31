// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

extension BrowserStore {
  var canReopenClosedTab: Bool {
    mayUseClosedTabs(in: session.selectedSpaceID)
      && !session.recentlyClosedTabs(in: session.selectedSpaceID).isEmpty
  }

  func showRecentlyClosed() {
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .recentlyClosed(spaceID: session.selectedSpaceID)
  }

  private func mayUseClosedTabs(in spaceID: UUID) -> Bool {
    guard session.selectedSpaceID == spaceID else { return false }
    if case .recentlyClosed(let owner) = sheet { return owner == spaceID }
    return sheet == nil
  }

  @discardableResult
  func reopenLastClosedTab() -> Bool {
    guard let entry = session.recentlyClosedTabs(in: session.selectedSpaceID).first else {
      return false
    }
    return reopenClosedTab(entry.id, in: session.selectedSpaceID)
  }

  @discardableResult
  func reopenClosedTab(_ id: UUID, in spaceID: UUID) -> Bool {
    guard mayUseClosedTabs(in: spaceID), session.reopenClosedTab(id, in: spaceID) != nil
    else { return false }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    if case .recentlyClosed = sheet { sheet = nil }
    save()
    return true
  }

  @discardableResult
  func clearClosedTabs(in spaceID: UUID) -> Bool {
    guard mayUseClosedTabs(in: spaceID), session.clearClosedTabs(in: spaceID) else { return false }
    save()
    return true
  }
}
