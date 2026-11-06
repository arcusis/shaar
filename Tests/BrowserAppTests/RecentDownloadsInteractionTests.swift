// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct RecentDownloadsInteractionTests {
  @Test func buttonActivationOpensAndClosesUntilDismissed() {
    let profile = UUID()
    var state = RecentDownloadsPresentation(profileID: profile)
    #expect(!state.isOpen)
    state.toggle(profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.isPinned)
    state.dismiss(profileID: profile, epoch: state.epoch)
    #expect(!state.isOpen && !state.isPinned)
    state.toggle(profileID: profile, epoch: state.epoch)
    state.toggle(profileID: profile, epoch: state.epoch)
    #expect(!state.isOpen && !state.isPinned)
  }

  @Test func profileChangeRejectsActionsFromPreviousProfile() {
    let old = UUID()
    let current = UUID()
    var state = RecentDownloadsPresentation(profileID: old)
    let oldEpoch = state.epoch
    state.selectProfile(current)
    state.toggle(profileID: old, epoch: oldEpoch)
    #expect(!state.isOpen && !state.isPinned)
    state.toggle(profileID: current, epoch: state.epoch)
    state.dismiss(profileID: old, epoch: oldEpoch)
    #expect(state.isOpen && state.isPinned)
  }
}
