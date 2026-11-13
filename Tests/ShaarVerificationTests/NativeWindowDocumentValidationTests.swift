// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct NativeWindowDocumentValidationTests {
  @Test func readyDocumentRequiresAuthoredFixtureAndInstance() {
    #expect(NativeWindowDocumentValidation.isReady(["fixture": "v1", "instance": "new"]))
    #expect(!NativeWindowDocumentValidation.isReady(["fixture": "v2", "instance": "new"]))
    #expect(!NativeWindowDocumentValidation.isReady(["fixture": "v1"]))
  }

  @Test func reloadWaitRejectsThePreviousDocumentInstance() {
    let document: [String: Any] = ["fixture": "v1", "instance": "same"]
    #expect(!NativeWindowDocumentValidation.isReady(document, differentFrom: "same"))
    #expect(NativeWindowDocumentValidation.isReady(document, differentFrom: "old"))
    #expect(NativeWindowDocumentValidation.isReady(document))
  }
}
