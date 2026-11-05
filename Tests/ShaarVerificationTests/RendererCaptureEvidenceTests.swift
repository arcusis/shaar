// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Foundation
import Testing

@Suite("Shaar renderer capture evidence")
struct RendererCaptureEvidenceTests {
  @Test func acceptsOnlyBoundedPNGBytesFromDevTools() {
    let pngHeader = Data([137, 80, 78, 71, 13, 10, 26, 10])
    #expect(ARCProbePNGFromDevToolsResult(["data": pngHeader.base64EncodedString()]) == pngHeader)
    #expect(
      ARCProbePNGFromDevToolsResult(["data": Data("not png".utf8).base64EncodedString()]) == nil)
    #expect(ARCProbePNGFromDevToolsResult(["data": "%%%"]) == nil)
    #expect(
      ARCProbePNGFromDevToolsResult(
        ["data": String(repeating: "A", count: 44 * 1024 * 1024 + 1)]) == nil)
  }
}
