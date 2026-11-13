// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ReloadWindowDocumentParserTests {
  @Test func parsesDocumentObjectsAndRejectsOtherJSONShapes() {
    let document = ReloadWindowProbe.parseDocumentJSON("{\"href\":\"https://example.invalid/\"}")
    #expect(document?["href"] as? String == "https://example.invalid/")
    #expect(ReloadWindowProbe.parseDocumentJSON("null") == nil)
    #expect(ReloadWindowProbe.parseDocumentJSON("false") == nil)
    #expect(ReloadWindowProbe.parseDocumentJSON("not JSON") == nil)
    #expect(ReloadWindowProbe.parseDocumentJSON(nil) == nil)
  }
}
