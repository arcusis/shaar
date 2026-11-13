// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func recentDownloadsActivationPinsThenSecondActivationDismisses() {
  let profileID = UUID()
  var presentation = RecentDownloadsPresentation(profileID: profileID)

  presentation.toggle(profileID: profileID, epoch: 0)
  #expect(presentation.isOpen)
  #expect(presentation.isPinned)

  presentation.toggle(profileID: profileID, epoch: 0)
  #expect(!presentation.isOpen)
  #expect(!presentation.isPinned)
}

@Test func recentDownloadsIgnoresStaleProfileAndEpochActions() {
  let profileID = UUID()
  var presentation = RecentDownloadsPresentation(profileID: profileID)
  presentation.toggle(profileID: UUID(), epoch: 0)
  presentation.dismiss(profileID: profileID, epoch: 1)
  #expect(!presentation.isOpen)
  #expect(!presentation.isPinned)

  presentation.toggle(profileID: profileID, epoch: 0)
  #expect(presentation.isOpen)
  presentation.selectProfile(UUID())
  #expect(presentation.epoch == 1)
  #expect(!presentation.isOpen)
  #expect(!presentation.isPinned)
}

@Test func recentDownloadsDismissalClearsPinnedState() {
  let profileID = UUID()
  var presentation = RecentDownloadsPresentation(profileID: profileID)
  presentation.toggle(profileID: profileID, epoch: 0)
  presentation.dismiss(profileID: profileID, epoch: 0)
  #expect(!presentation.isOpen)
  #expect(!presentation.isPinned)
}
