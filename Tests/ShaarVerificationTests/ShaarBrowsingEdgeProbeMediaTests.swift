// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeMediaTests {
  @Test func videoMustBeUnpausedToPassTheMediaProbe() {
    #expect(ShaarBrowsingEdgeProbe.videoIsPlaying(["video": true, "paused": false]))
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying(["video": true, "paused": true]))
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying(["video": true]))
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying(["video": false, "paused": false]))
  }
}
