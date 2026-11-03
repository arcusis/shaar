// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test @MainActor func browserImportPreviewRendersReadyAndErrorStatesOffscreen() throws {
  let item = BrowserImportItem(title: "Research", address: "https://example.com", folder: "Work")
  let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
    "import-preview.png")
  defer { try? FileManager.default.removeItem(at: destination) }
  let ready = BrowserImportPreviewView(
    items: [item], profileName: "Work", error: nil, canImport: true,
    onCancel: {}, onImport: {})
  let readyImage = try VisualCapture.renderOffscreen(
    ready, size: NSSize(width: 520, height: 440), appearance: .aqua, to: destination)
  #expect(readyImage.size == NSSize(width: 520, height: 440))

  let failed = BrowserImportPreviewView(
    items: [], profileName: "Work", error: "Unsupported file", canImport: false,
    onCancel: {}, onImport: {})
  let failedImage = try VisualCapture.renderOffscreen(
    failed, size: NSSize(width: 520, height: 440), appearance: .aqua, to: destination)
  #expect(failedImage.size == NSSize(width: 520, height: 440))

  let store = BrowserStore()
  let library = LibraryPanel(
    store: store, profileID: store.session.selectedSpace.profileID, section: .bookmarks)
  let libraryImage = try VisualCapture.renderOffscreen(
    library, size: NSSize(width: 600, height: 480), appearance: .aqua, to: destination)
  #expect(libraryImage.size == NSSize(width: 600, height: 480))
}
