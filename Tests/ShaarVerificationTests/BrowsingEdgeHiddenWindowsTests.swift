// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite
struct BrowsingEdgeHiddenWindowsTests {
  @Test func aVisibleNoteFailsTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: [],
      notes: [["kind": "visible", "class": "NSWindow", "title": "Leak"]])
    #expect(detail == "Visible during the run: Leak")
  }

  @Test func aWindowLeftUpFailsTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: ["Shaar"], notes: [])
    #expect(detail == "Still visible: Shaar")
  }

  @Test func aPrintPanelMatchesClassOrTitle() {
    #expect(browsingEdgePrintSurface(["kind": "modal", "class": "NSPrintPanel", "title": ""]))
    #expect(browsingEdgePrintSurface(["kind": "visible", "class": "NSWindow", "title": "Print"]))
    #expect(!browsingEdgePrintSurface(["kind": "modal", "class": "NSWindow", "title": "Alert"]))
    #expect(!browsingEdgePrintSurface(["kind": "sheet", "class": "NSPanel", "title": ""]))
  }

  @Test func aFileChooserMatchesOnlyAnOpenPanel() {
    #expect(browsingEdgeFileChooserOpened(["kind": "open-panel"]))
    #expect(!browsingEdgeFileChooserOpened(["kind": "save-panel"]))
    #expect(!browsingEdgeFileChooserOpened(["kind": "modal"]))
    #expect(!browsingEdgeFileChooserOpened(["kind": "sheet"]))
  }

  @Test func anOpenPanelDoesNotFailTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: [],
      notes: [["kind": "open-panel", "class": "NSOpenPanel", "title": "Open"]])
    #expect(detail == nil)
  }

  @Test func hittingTheNoteCapFailsTheRow() {
    var notes: [[String: String]] = []
    var seen = Set<String>()
    var dropped = false
    for index in 0..<browsingEdgeDialogNoteCap {
      browsingEdgeRecordNote(
        notes: &notes, seen: &seen, dropped: &dropped,
        note: ["kind": "modal", "title": "\(index)"],
        key: "modal|\(index)")
    }
    #expect(notes.count == browsingEdgeDialogNoteCap)
    #expect(!dropped)
    browsingEdgeRecordNote(
      notes: &notes, seen: &seen, dropped: &dropped,
      note: ["kind": "visible", "class": "NSWindow", "title": "Leak"],
      key: "visible|Leak")
    #expect(dropped)
    #expect(notes.count == browsingEdgeDialogNoteCap)
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: [], notes: notes, notesDropped: dropped)
    #expect(detail == "Dialog note cap was hit, so a later window was not recorded")
    let verdict = browsingEdgeHiddenWindowsVerdict(
      stillVisible: [], notes: notes, notesDropped: true)
    #expect(!verdict.passed)
    #expect(verdict.detail.contains("50 ms"))
  }

  @Test func aRepeatedNoteDoesNotTripTheCap() {
    var notes: [[String: String]] = []
    var seen = Set<String>()
    var dropped = false
    let note = ["kind": "modal", "title": "Same"]
    for _ in 0..<(browsingEdgeDialogNoteCap + 5) {
      browsingEdgeRecordNote(
        notes: &notes, seen: &seen, dropped: &dropped, note: note, key: "modal|Same")
    }
    #expect(notes.count == 1)
    #expect(!dropped)
  }

  @Test func theSamplingGapIsStatedWhenNothingWasVisible() {
    let verdict = browsingEdgeHiddenWindowsVerdict(
      stillVisible: [], notes: [], notesDropped: false)
    #expect(verdict.passed)
    #expect(verdict.detail == "No window was left visible. \(browsingEdgeDialogSampleGap())")
    #expect(browsingEdgeDialogSampleGap().contains("50 ms"))
  }
}
