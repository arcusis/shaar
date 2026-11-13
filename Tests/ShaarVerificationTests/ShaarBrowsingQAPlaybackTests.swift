// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAPlaybackTests {
  @Test func readinessRequiresPlayingVideoOrAnExplicitPlaybackError() {
    #expect(!ShaarBrowsingQA.playbackSettled(nil))
    #expect(!ShaarBrowsingQA.playbackSettled("{}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"paused\":true,\"width\":320}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"paused\":false,\"width\":0}"))
    #expect(ShaarBrowsingQA.playbackSettled("{\"paused\":false,\"width\":320}"))
    #expect(ShaarBrowsingQA.playbackSettled("{\"error\":3}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"error\":0,\"paused\":true,\"width\":0}"))
  }
}
