// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQABeforeUnloadTests {
  @Test func beforeUnloadPassRequiresTheCompleteArmedPromptCancellationReceipt() {
    #expect(
      ShaarBrowsingQA.beforeUnloadStatus(
        armed: true, armedState: "1", prompted: true, dialogRequestQueued: true,
        dialogSheetPresented: true, cancelled: true,
        sawVisibleDialog: false, dismissed: true) == "pass")

    for missing in [
      "armed", "armedState", "prompted", "dialogRequestQueued", "cancelled", "dismissed",
      "dialogSheetPresented",
    ] {
      #expect(
        ShaarBrowsingQA.beforeUnloadStatus(
          armed: missing != "armed", armedState: missing == "armedState" ? "0" : "1",
          prompted: missing != "prompted",
          dialogRequestQueued: missing != "dialogRequestQueued",
          dialogSheetPresented: missing != "dialogSheetPresented",
          cancelled: missing != "cancelled",
          sawVisibleDialog: false, dismissed: missing != "dismissed") == "fail")
    }
  }

  @Test func visibleDialogIsBlockedEvenWhenTheOtherEvidenceLooksSuccessful() {
    #expect(
      ShaarBrowsingQA.beforeUnloadStatus(
        armed: true, armedState: "1", prompted: true, dialogRequestQueued: true,
        dialogSheetPresented: true, cancelled: true,
        sawVisibleDialog: true, dismissed: true) == "blocked")
  }
}
