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
    #expect(ShaarBrowsingQA.playbackSettled("{ \"width\": 320, \"paused\": false }"))
    #expect(ShaarBrowsingQA.playbackSettled("{\"error\":3}"))
    #expect(ShaarBrowsingQA.playbackSettled("{ \"error\": 3 }"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"error\":0,\"paused\":true,\"width\":0}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"error\":false,\"paused\":false,\"width\":320}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"paused\":false,\"width\":true}"))
    #expect(!ShaarBrowsingQA.playbackSettled("not JSON with \"error\":3"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"error\":\"3\"}"))
  }

  @Test func playbackVerdictParsesJSONEvidenceAndRejectsMalformedData() {
    #expect(
      ShaarBrowsingQA.playbackStarted(
        "{\"paused\":false,\"width\":320,\"error\":0,\"click\":\"true\",\"playResult\":\"resolved\"}"))
    #expect(
      ShaarBrowsingQA.playbackStarted(
        "{ \"error\": 0, \"width\": 320, \"paused\": false, \"click\": \"true\", \"playResult\": \"resolved\" }"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":true,\"width\":320,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":0,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":320,\"error\":3}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":320}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":320,\"error\":false}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":true,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("not JSON with \"paused\":false \"error\":0"))
  }

  @Test func playbackVerdictRequiresPlayingVideoWithPictureAndNoError() {
    #expect(!ShaarBrowsingQA.playbackStarted(nil))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":true,\"width\":320,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":0,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":false,\"width\":320,\"error\":3}"))
    #expect(
      ShaarBrowsingQA.playbackStarted(
        "{\"paused\":false,\"width\":320,\"error\":0,\"click\":\"true\",\"playResult\":\"resolved\"}"))
  }

  @Test func playbackVerdictRequiresTrustedClickAndResolvedPlayPromise() {
    #expect(
      !ShaarBrowsingQA.playbackStarted(
        "{\"paused\":false,\"width\":320,\"error\":0,\"click\":\"false\",\"playResult\":\"resolved\"}"))
    #expect(
      !ShaarBrowsingQA.playbackStarted(
        "{\"paused\":false,\"width\":320,\"error\":0,\"click\":\"true\",\"playResult\":\"NotAllowedError\"}"))
  }

  @Test func playbackVerdictRejectsNumericPausedValues() {
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":0,\"width\":320,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackStarted("{\"paused\":1,\"width\":320,\"error\":0}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"paused\":0,\"width\":320}"))
    #expect(!ShaarBrowsingQA.playbackSettled("{\"paused\":1,\"width\":320}"))
  }
}
