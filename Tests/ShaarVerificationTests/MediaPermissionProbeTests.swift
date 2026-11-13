// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite("Media permission result parsing")
struct MediaPermissionProbeTests {
  @Test func allowedResultRequiresBooleanTrue() {
    #expect(MediaPermissionProbe.isAllowedResponse(["allowed": true]))
    #expect(!MediaPermissionProbe.isAllowedResponse(["allowed": false]))
    #expect(!MediaPermissionProbe.isAllowedResponse(["allowed": 1]))
    #expect(!MediaPermissionProbe.isAllowedResponse(["allowed": "true"]))
    #expect(!MediaPermissionProbe.isAllowedResponse([:]))
  }

  @Test func mediaTracksRequireExactIntegerCounts() {
    #expect(MediaPermissionProbe.hasExpectedTrackCounts(["audio": 1, "video": 1]))
    for result: [String: Any] in [
      ["audio": true, "video": 1],
      ["audio": 1, "video": false],
      ["audio": 1.5, "video": 1],
      ["audio": "1", "video": 1],
      ["audio": 1],
    ] {
      #expect(!MediaPermissionProbe.hasExpectedTrackCounts(result))
    }
  }
}
