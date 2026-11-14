// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
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

  @Test func fileUploadPassRequiresTheChooserAndExactReturnedFile() {
    #expect(
      browsingEdgeFileUploadPassed(
        clicked: true, chooserRequested: true,
        returnedName: "upload.txt", returnedContents: "payload",
        expectedName: "upload.txt", expectedContents: "payload", windowsHidden: true))
    #expect(
      !browsingEdgeFileUploadPassed(
        clicked: true, chooserRequested: false,
        returnedName: "upload.txt", returnedContents: "payload",
        expectedName: "upload.txt", expectedContents: "payload", windowsHidden: true))
    #expect(
      !browsingEdgeFileUploadPassed(
        clicked: true, chooserRequested: true,
        returnedName: "upload.txt", returnedContents: "other",
        expectedName: "upload.txt", expectedContents: "payload", windowsHidden: true))
    #expect(
      !browsingEdgeFileUploadPassed(
        clicked: true, chooserRequested: true,
        returnedName: "upload.txt", returnedContents: "payload",
        expectedName: "upload.txt", expectedContents: "payload", windowsHidden: false))
    #expect(
      !browsingEdgeFileUploadPassed(
        clicked: true, chooserRequested: true,
        returnedName: "other.txt", returnedContents: "payload",
        expectedName: "upload.txt", expectedContents: "payload", windowsHidden: true))
  }

  @MainActor @Test func syntheticOpenPanelReturnsTheFixtureWithoutShowingIt() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "shaar-open-panel-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
      BrowsingEdgeFilePickerSelection.uninstall()
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appending(path: "selected.txt")
    try Data("selected content".utf8).write(to: fileURL)
    let installed = BrowsingEdgeFilePickerSelection.install(fileURL: fileURL)
    #expect(installed)
    guard installed else { return }

    let panel = NSOpenPanel()
    #expect(panel.runModal() == .OK)
    #expect(panel.url == fileURL)
    #expect(panel.urls == [fileURL])
    #expect(BrowsingEdgeFilePickerSelection.wasRequested)
    #expect(!panel.isVisible)
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

  @Test @MainActor func dialogReplyNeedsTheValueReturnedByTheRenderer() {
    #expect(ShaarBrowsingEdgeProbe.dialogReplyPassed(name: "alert", result: ["stage": "returned"]))
    #expect(
      !ShaarBrowsingEdgeProbe.dialogReplyPassed(
        name: "confirm", result: ["stage": "returned", "value": false]))
    #expect(
      ShaarBrowsingEdgeProbe.dialogReplyPassed(
        name: "confirm", result: ["stage": "returned", "value": true]))
    #expect(
      !ShaarBrowsingEdgeProbe.dialogReplyPassed(
        name: "prompt", result: ["stage": "returned", "value": "cancelled"]))
    #expect(
      ShaarBrowsingEdgeProbe.dialogReplyPassed(
        name: "prompt", result: ["stage": "returned", "value": "edge-answer"]))
  }
}
