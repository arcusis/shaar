// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStorePictureInPictureTests {
  @Test func localFilesRemainAllowedAndMissingTabsFailClosed() {
    let store = BrowserStore()
    let profileID = store.session.selectedSpace.profileID
    store.preferences.setAutomaticPictureInPicture(false, on: "example.test", for: profileID)

    #expect(
      store.automaticPictureInPictureAllowed(
        for: URL(fileURLWithPath: "/tmp/video.mov"), profileID: profileID))
    #expect(!store.automaticPictureInPictureAllowed(forTab: UUID()))
  }
}
