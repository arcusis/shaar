// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Owns only recent-card presentation; download authority stays in DownloadsModel.
struct RecentDownloadsPresentation {
  private(set) var profileID: UUID
  private(set) var isOpen = false
  private(set) var isPinned = false
  private(set) var epoch: UInt64 = 0

  init(profileID: UUID) {
    self.profileID = profileID
  }

  /// A button activation toggles the card until the next activation or dismissal.
  mutating func toggle(profileID: UUID, epoch: UInt64) {
    guard profileID == self.profileID, epoch == self.epoch else { return }
    if isPinned {
      dismiss(profileID: profileID, epoch: epoch)
    } else {
      isPinned = true
      isOpen = true
    }
  }

  mutating func dismiss(profileID: UUID, epoch: UInt64) {
    guard profileID == self.profileID, epoch == self.epoch else { return }
    isOpen = false
    isPinned = false
  }

  mutating func selectProfile(_ profileID: UUID) {
    epoch &+= 1
    self.profileID = profileID
    isOpen = false
    isPinned = false
  }
}
