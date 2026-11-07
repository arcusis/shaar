// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct DevToolsSourceBytesProofTests {
  @Test func scaleSourceKeepsTheMarkersAndPadding() {
    let prefix = "/* shaar-scale-source\n"
    let suffix = "\nshaar-scale-end */\n"
    let byteCount = prefix.utf8.count + 8 + suffix.utf8.count
    let content = prefix + String(repeating: "x", count: 8) + suffix
    #expect(DevToolsSourceBytesProof.isScaleSource(content, byteCount: byteCount))
    #expect(!DevToolsSourceBytesProof.isScaleSource(content, byteCount: byteCount - 1))
    let wrongPadding = prefix + "yxxxxxxx" + suffix
    #expect(!DevToolsSourceBytesProof.isScaleSource(wrongPadding, byteCount: byteCount))
  }
}
