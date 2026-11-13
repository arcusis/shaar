// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ProfileDeletionConfirmationTests {
  @Test func initialMoveDestinationExcludesTheProfileBeingDeleted() {
    let deleting = BrowserSettingsProfile(id: UUID(), name: "Personal", spaces: [])
    let firstAlternative = BrowserSettingsProfile(id: UUID(), name: "Work", spaces: [])
    let secondAlternative = BrowserSettingsProfile(id: UUID(), name: "School", spaces: [])

    #expect(
      ProfileDeletionConfirmation.initialDestinationID(
        for: deleting.id, in: [deleting, firstAlternative, secondAlternative])
        == firstAlternative.id)
  }

  @Test func noMoveDestinationExistsWhenThereIsNoOtherProfile() {
    let onlyProfile = BrowserSettingsProfile(id: UUID(), name: "Personal", spaces: [])

    #expect(
      ProfileDeletionConfirmation.initialDestinationID(for: onlyProfile.id, in: [onlyProfile])
        == nil)
  }
}
