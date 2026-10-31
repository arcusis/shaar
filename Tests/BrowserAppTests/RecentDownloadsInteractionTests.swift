// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct RecentDownloadsInteractionTests {
  @Test func buttonActivationPinsUntilDismissed() {
    let profile = UUID()
    var state = RecentDownloadsPresentation(profileID: profile)
    #expect(!state.isOpen)
    state.toggle(profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.isPinned)
    let leave = state.hover(.anchor, inside: false, profileID: profile, epoch: state.epoch)!
    state.finishHoverLeave(token: leave, profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.isPinned)
    // The sidebar's Escape handler and close button call this same operation.
    state.dismiss(profileID: profile, epoch: state.epoch)
    #expect(!state.isOpen && !state.isPinned)
    state.toggle(profileID: profile, epoch: state.epoch)
    state.toggle(profileID: profile, epoch: state.epoch)
    #expect(!state.isOpen && !state.isPinned)
  }

  @Test func anchorToCardTransitionRejectsEarlierClose() {
    let profile = UUID()
    var state = RecentDownloadsPresentation(profileID: profile)
    _ = state.hover(.anchor, inside: true, profileID: profile, epoch: state.epoch)
    let oldLeave = state.hover(.anchor, inside: false, profileID: profile, epoch: state.epoch)!
    _ = state.hover(.card, inside: true, profileID: profile, epoch: state.epoch)
    state.finishHoverLeave(token: oldLeave, profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.cardHovered)
    let cardLeave = state.hover(.card, inside: false, profileID: profile, epoch: state.epoch)!
    state.finishHoverLeave(token: cardLeave, profileID: profile, epoch: state.epoch)
    #expect(!state.isOpen)
  }

  @Test func keyboardActivationPinsCardAlreadyOpenedByHover() {
    let profile = UUID()
    var state = RecentDownloadsPresentation(profileID: profile)
    _ = state.hover(.anchor, inside: true, profileID: profile, epoch: state.epoch)
    state.toggle(profileID: profile, epoch: state.epoch)
    let leave = state.hover(.anchor, inside: false, profileID: profile, epoch: state.epoch)!
    state.finishHoverLeave(token: leave, profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.isPinned)
  }

  @Test func profileChangeRejectsOldHoverToggleAndDismissCallbacks() {
    let old = UUID()
    let current = UUID()
    var state = RecentDownloadsPresentation(profileID: old)
    let oldEpoch = state.epoch
    _ = state.hover(.anchor, inside: true, profileID: old, epoch: oldEpoch)
    let oldLeave = state.hover(.anchor, inside: false, profileID: old, epoch: oldEpoch)!
    state.selectProfile(current)
    #expect(!state.isOpen && !state.isPinned && !state.anchorHovered && !state.cardHovered)
    state.toggle(profileID: current, epoch: state.epoch)
    state.finishHoverLeave(token: oldLeave, profileID: old, epoch: oldEpoch)
    state.dismiss(profileID: old, epoch: oldEpoch)
    state.toggle(profileID: old, epoch: oldEpoch)
    _ = state.hover(.card, inside: true, profileID: old, epoch: oldEpoch)
    #expect(state.profileID == current && state.isOpen && state.isPinned && !state.cardHovered)
  }

  @Test func dismissInvalidatesPendingCloseBeforeReopen() {
    let profile = UUID()
    var state = RecentDownloadsPresentation(profileID: profile)
    _ = state.hover(.anchor, inside: true, profileID: profile, epoch: state.epoch)
    let oldLeave = state.hover(.anchor, inside: false, profileID: profile, epoch: state.epoch)!
    state.dismiss(profileID: profile, epoch: state.epoch)
    state.toggle(profileID: profile, epoch: state.epoch)
    state.finishHoverLeave(token: oldLeave, profileID: profile, epoch: state.epoch)
    #expect(state.isOpen && state.isPinned)
  }

  @Test func returnToProfileRejectsCallbacksFromEarlierVisit() {
    let a = UUID()
    let b = UUID()
    var state = RecentDownloadsPresentation(profileID: a)
    let oldEpoch = state.epoch
    _ = state.hover(.anchor, inside: true, profileID: a, epoch: oldEpoch)
    let oldLeave = state.hover(.anchor, inside: false, profileID: a, epoch: oldEpoch)!
    state.selectProfile(b)
    state.selectProfile(a)
    state.toggle(profileID: a, epoch: state.epoch)
    state.dismiss(profileID: a, epoch: oldEpoch)
    state.finishHoverLeave(token: oldLeave, profileID: a, epoch: oldEpoch)
    _ = state.hover(.card, inside: true, profileID: a, epoch: oldEpoch)
    #expect(state.isOpen && state.isPinned && !state.cardHovered)
  }
}
