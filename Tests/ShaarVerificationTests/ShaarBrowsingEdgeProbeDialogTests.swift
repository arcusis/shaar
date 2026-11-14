// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeDialogTests {
  @Test func dialogNotesDeduplicateBeforeEnforcingTheCap() {
    var notes: [[String: String]] = []
    var seen: Set<String> = []
    var dropped = false
    for index in 0..<browsingEdgeDialogNoteCap {
      browsingEdgeRecordNote(
        notes: &notes, seen: &seen, dropped: &dropped,
        note: ["kind": "visible", "title": "Window \(index)"], key: "\(index)")
    }
    browsingEdgeRecordNote(
      notes: &notes, seen: &seen, dropped: &dropped,
      note: ["kind": "visible", "title": "Duplicate"], key: "0")
    #expect(notes.count == browsingEdgeDialogNoteCap)
    #expect(!dropped)

    browsingEdgeRecordNote(
      notes: &notes, seen: &seen, dropped: &dropped,
      note: ["kind": "visible", "title": "Overflow"], key: "overflow")
    #expect(notes.count == browsingEdgeDialogNoteCap)
    #expect(dropped)
  }

  @Test func printAndFileChooserEvidenceRequiresTheirExpectedSignals() {
    #expect(browsingEdgePrintSurface(["class": "NSPrintPanel"]))
    #expect(browsingEdgePrintSurface(["title": "Print Preview"]))
    #expect(!browsingEdgePrintSurface(["class": "NSOpenPanel", "title": "Choose file"]))
    #expect(browsingEdgeFileChooserOpened(["kind": "open-panel"]))
    #expect(!browsingEdgeFileChooserOpened(["kind": "save-panel"]))
  }

  @Test func hiddenWindowFailureReportsVisibleAndDroppedDialogEvidence() {
    let notes = [["kind": "visible", "title": "Unexpected chooser"]]
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: ["BrowserWindow"], notes: notes, notesDropped: true)
    #expect(detail?.contains("Unexpected chooser") == true)
    #expect(detail?.contains("Still visible: BrowserWindow") == true)
    #expect(detail?.contains("note cap was hit") == true)

    let verdict = browsingEdgeHiddenWindowsVerdict(
      stillVisible: [], notes: [], notesDropped: false)
    #expect(verdict.passed)
    #expect(verdict.detail.contains("No window was left visible"))
  }

  @Test func beforeUnloadRequiresNavigationAfterTheDialog() {
    #expect(
      ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: true, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: false, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 0, navigated: true, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: true, windowsHidden: false))
  }
}
