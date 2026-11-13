// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PageFindDocumentReadinessTests {
  @Test func targetRequiresAuthoredFixtureCompletedLoadAndRequestedText() {
    #expect(PageFindDocumentReadiness.isReady([
      "fixture": "v1", "ready": "complete", "text": true,
    ]))
    #expect(!PageFindDocumentReadiness.isReady([
      "fixture": "v2", "ready": "complete", "text": true,
    ]))
    #expect(!PageFindDocumentReadiness.isReady([
      "fixture": "v1", "ready": "loading", "text": true,
    ]))
    #expect(!PageFindDocumentReadiness.isReady([
      "fixture": "v1", "ready": "complete", "text": false,
    ]))
    #expect(!PageFindDocumentReadiness.isReady(["fixture": "v1", "ready": "complete"]))
  }
}
