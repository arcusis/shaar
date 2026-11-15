// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PrivateDiskArtifactBaselineTests {
  @Test func checkpointsOnlyFilesChangedByNormalPositiveControls() {
    let baseline = [
      "Chromium/History": "10:1",
      "Chromium/Local Storage/leveldb/000003.log": "20:2",
    ]
    let beforeControls = [
      "Chromium/History": "11:3",
      "Chromium/Local Storage/leveldb/000003.log": "20:2",
    ]
    let afterControls = [
      "Chromium/History": "11:3",
      "Chromium/Local Storage/leveldb/000003.log": "30:4",
      "Chromium/Session Storage/000003.log": "15:5",
    ]

    let checkpoint = PrivateDiskArtifactBaseline.checkpointNormalControlChanges(
      baseline: baseline, beforeControls: beforeControls, afterControls: afterControls)

    #expect(checkpoint["Chromium/History"] == "10:1")
    #expect(checkpoint["Chromium/Local Storage/leveldb/000003.log"] == "30:4")
    #expect(checkpoint["Chromium/Session Storage/000003.log"] == "15:5")
    #expect(checkpoint["Chromium/Local Storage/leveldb/000003.log"] != "31:6")
  }
}
