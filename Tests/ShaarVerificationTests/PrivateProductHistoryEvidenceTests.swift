// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Private product history evidence")
struct PrivateProductHistoryEvidenceTests {
  @Test func successfulEmptyHistoryProvesNoPrivateProductVisit() {
    #expect(
      PrivateProductHostProbe.historyExcludesProductVisit(rows: [], error: nil, runID: "run-1"))
  }

  @Test func matchingVisitFailsWhileUnrelatedRowsPass() {
    #expect(
      !PrivateProductHostProbe.historyExcludesProductVisit(
        rows: [["u": "https://example.test/private-product-run-1"]], error: nil,
        runID: "RUN-1"))
    #expect(
      PrivateProductHostProbe.historyExcludesProductVisit(
        rows: [["u": "https://example.test/ordinary"]], error: nil, runID: "run-1"))
  }

  @Test func missingRowsAndQueryErrorsDoNotCountAsEvidence() {
    let error = NSError(domain: "history", code: 1)
    #expect(!PrivateProductHostProbe.historyExcludesProductVisit(rows: nil, error: nil, runID: "x"))
    #expect(
      !PrivateProductHostProbe.historyExcludesProductVisit(rows: [], error: error, runID: "x"))
  }
}
