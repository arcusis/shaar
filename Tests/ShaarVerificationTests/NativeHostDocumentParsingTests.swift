// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct NativeHostDocumentParsingTests {
  @Test func acceptsOnlyReadyFixtureDocuments() {
    let document = NativeHostProbe.parseDocumentJSON(
      "{\"fixture\":\"v1\",\"instance\":\"instance-1\",\"innerWidth\":1280}")
    #expect(document?["instance"] as? String == "instance-1")

    #expect(
      NativeHostProbe.parseDocumentJSON("{\"fixture\":\"v2\",\"instance\":\"x\"}") == nil)
    #expect(
      NativeHostProbe.parseDocumentJSON("{\"fixture\":\"v1\",\"instance\":\"\"}") == nil)
    #expect(NativeHostProbe.parseDocumentJSON("{\"fixture\":\"v1\"}") == nil)
    #expect(NativeHostProbe.parseDocumentJSON("false") == nil)
    #expect(NativeHostProbe.parseDocumentJSON("not JSON") == nil)
    #expect(NativeHostProbe.parseDocumentJSON(nil) == nil)
  }
}
