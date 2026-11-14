// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorAICopyTests {
  @Test func backendFailuresUseLocalizedCopyRecoveryCopy() {
    let error = NSError(domain: "DevTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
    #expect(
      InspectorAICopyModel.failureMessage(for: error)
        == InspectorL10n.string("Could not copy the selected element. Try again."))
    let known = InspectorFailure("Lock an element first.")
    #expect(
      InspectorAICopyModel.failureMessage(for: known)
        == InspectorL10n.display(known.localizedDescription))
  }

  private func inspector() -> InspectorModel {
    let model = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    model.open()
    return model
  }

  @Test func cancelledCopyDoesNotStartInspectorRequestOrShowFailure() async throws {
    let model = inspector()
    defer { model.close() }
    try model.receive(InspectorPanelTests.fixtureSelection())

    let copy = Task { @MainActor in await model.aiCopy.copy(.element) }
    copy.cancel()
    await copy.value

    #expect(model.aiCopy.failure == nil)
    #expect(!model.aiCopy.busy)
  }

  @Test func cancelledNoteDoesNotStartInspectorRequestOrShowFailure() async throws {
    let model = inspector()
    defer { model.close() }
    try model.receive(InspectorPanelTests.fixtureSelection())
    model.aiCopy.feedback = "Add a label"

    let note = Task { @MainActor in await model.aiCopy.addNote() }
    note.cancel()
    await note.value

    #expect(model.aiCopy.notes.isEmpty)
    #expect(model.aiCopy.failure == nil)
    #expect(!model.aiCopy.busy)
  }

  @Test func notesStayPerTabAcrossNavigationAndCloseAndUndoPreservesNewNotes() throws {
    let one = inspector()
    let two = inspector()
    defer {
      one.close()
      two.close()
    }
    let notes = one.aiCopy
    let context = InspectorAIFormatterTests.context()
    notes.append(context: context, feedback: "Change spacing", intent: .change)
    one.documentChanged(url: URL(string: "https://example.com/next")!, committed: true)
    one.close()
    one.open()
    #expect(notes.notes.count == 1 && two.aiCopy.notes.isEmpty)
    notes.clear()
    #expect(notes.notes.isEmpty && notes.clearedNotes.count == 1)
    notes.append(context: context, feedback: "New note", intent: .question)
    notes.undoClear()
    #expect(notes.notes.map(\.feedback) == ["Change spacing", "New note"])
    notes.delete(notes.notes[0].id)
    #expect(notes.notes.count == 1)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    notes.copyNotes(to: board)
    #expect(board.pasteboardItems?.count == 1)
    #expect(board.string(forType: .string)?.contains("Design Feedback: Account") == true)
    #expect(notes.notes.isEmpty && notes.clearedNotes.count == 1)
    notes.undoClear()
    #expect(notes.notes.count == 1 && notes.clearedNotes.isEmpty)
    notes.append(context: context, feedback: " \n ", intent: .important)
    #expect(notes.notes.count == 1)
    var bad = context
    bad.protected = true
    notes.append(context: bad, feedback: "Never attach form", intent: .change)
    #expect(notes.notes.count == 1)
  }
  @Test func undoAtNoteLimitNeverDropsNewOrClearedFeedback() {
    let parent = inspector()
    let model = parent.aiCopy
    defer { parent.close() }
    let context = InspectorAIFormatterTests.context()
    for _ in 0..<50 { model.append(context: context, feedback: "Original", intent: .change) }
    model.clear()
    for _ in 0..<50 { model.append(context: context, feedback: "New", intent: .question) }
    model.undoClear()
    #expect(model.notes.count == 50 && model.notes.allSatisfy { $0.feedback == "New" })
    #expect(model.clearedNotes.count == 50)
    model.delete(model.notes[0].id)
    model.undoClear()
    #expect(model.notes.count == 50 && model.notes.first?.feedback == "Original")
    #expect(
      model.notes.filter { $0.feedback == "New" }.count == 49 && model.clearedNotes.count == 49)
  }

  @Test func clipboardHasMarkdownAndRealPNGOnOneItemAndCorruptionDoesNotReplaceIt() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try InspectorAICopyModel.write("Markdown fixture", png: png, to: board)
    let items = try #require(board.pasteboardItems)
    #expect(items.count == 1)
    #expect(items[0].string(forType: .string) == "Markdown fixture")
    #expect(items[0].string(forType: .init("net.daringfireball.markdown")) == "Markdown fixture")
    #expect(items[0].data(forType: .png) == png)
    let count = board.changeCount
    #expect(throws: InspectorFailure.self) {
      try InspectorAICopyModel.write(
        "Bad image", png: Data([137, 80, 78, 71, 13, 10, 26, 10]), to: board)
    }
    #expect(board.changeCount == count)
    try InspectorAICopyModel.write(nil, png: png, to: board)
    #expect(board.pasteboardItems?.count == 1 && board.data(forType: .png) == png)
    #expect(board.string(forType: .string) == nil)
  }

  @Test func screenshotCachePrunesOnlyOwnedOldFilesAndKeepsPrivatePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date.now
    let old = root.appending(path: "123-section.png")
    let recent = root.appending(path: "124-button.png")
    let unrelated = root.appending(path: "unrelated.png")
    for file in [old, recent, unrelated] { try Data([1, 2, 3]).write(to: file) }
    for file in [old, unrelated] {
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: file.path)
    }
    let link = root.appending(path: "125-section.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    let saved = try InspectorScreenshotCache(directory: root).save(
      png, tag: "../../<SECTION>", now: now)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == unrelated.path)
    #expect(saved.lastPathComponent.hasSuffix("-section.png"))
    #expect(try Data(contentsOf: saved) == png)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)
  }

  @Test func screenshotCacheRejectsSymlinkedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let target = root.appending(path: "outside", directoryHint: .isDirectory)
    let directory = root.appending(path: "Inspector", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)

    #expect(throws: CocoaError.self) {
      try InspectorScreenshotCache(directory: directory).save(Data([1, 2, 3]), tag: "section")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
  }

  @Test func screenshotCacheTightensExistingDirectoryPermissions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

    _ = try InspectorScreenshotCache(directory: root).save(Data([1, 2, 3]), tag: "private")

    let permissions =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
  }

  @Test func unavailableOrClosedSelectionFailsWithoutTouchingClipboard() async throws {
    let model = inspector()
    defer { model.close() }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let count = board.changeCount
    await model.aiCopy.copyElement(to: board)
    #expect(model.aiCopy.failure == "Lock an element first.")
    try model.receive(InspectorPanelTests.fixtureSelection())
    await model.aiCopy.copyElement(to: board)
    #expect(model.aiCopy.failure != nil && !model.aiCopy.busy)
    model.aiCopy.feedback = "Comment"
    await model.aiCopy.addNote()
    #expect(model.aiCopy.notes.isEmpty && !model.aiCopy.busy)
    model.close()
    #expect(!model.aiCopy.canCopy && board.changeCount == count)
  }
  @Test func noteViewsRenderAllStatesOffscreen() async throws {
    let model = inspector()
    defer { model.close() }
    try model.receive(InspectorPanelTests.fixtureSelection())
    for scheme in [ColorScheme.light, .dark] {
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: model), scheme: scheme).count
          > 4096)
      model.tab = .notes
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: model), scheme: scheme).count
          > 4096)
      model.aiCopy.feedback = "Make selected element clearer."
      model.aiCopy.detailed = true
      model.aiCopy.append(
        context: InspectorAIFormatterTests.context(), feedback: "Keep the button",
        intent: .important)
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: model), scheme: scheme).count
          > 4096)
      model.aiCopy.clear()
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: model), scheme: scheme).count
          > 4096)
      model.aiCopy.undoClear()
      model.tab = .design
    }
  }
  @Test func exactScriptParsesAndShortcutIsReservedWithoutOtherChords() throws {
    let context = try #require(JSContext())
    #expect(
      context.evaluateScript("source=>{new Function(source);return true;}")?.call(withArguments: [
        InspectorAICopyScript.install
      ])?.toBool() == true)
    #expect(context.exception == nil)
    #expect(ARCReservedBrowserShortcut("c", [.command, .shift]))
    #expect(ARCReservedBrowserShortcut("c", [.command, .shift, .option]))
    #expect(!ARCReservedBrowserShortcut("c", [.command, .shift, .control]))
    #expect(ShortcutCatalog.displayKeys(for: .inspectorCopy) == "⇧⌘C")
  }
}
