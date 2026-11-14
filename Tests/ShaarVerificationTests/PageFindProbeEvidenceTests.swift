// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PageFindProbeEvidenceTests {
  @Test func readinessRequiresFixtureCompletionAndBooleanTextMatch() {
    #expect(
      PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "complete", "text": true]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "wrong", "ready": "complete", "text": true]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "loading", "text": true]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "complete", "text": false]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "complete", "text": 1]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "complete", "text": "true"]))
    #expect(
      !PageFindProbeEvidence.isReadyDocument(
        ["fixture": "v1", "ready": "complete"]))
  }
}
