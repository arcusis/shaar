// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func browserImportPreviewSummaryUsesHebrewDualForms() {
  func readable(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{2068}", with: "")
      .replacingOccurrences(of: "\u{2069}", with: "")
  }
  #expect(
    readable(
      BrowserImportPreviewCounts.summary(
        bookmarks: 1, history: 1, profileName: "Work", language: .hebrew))
      == "סימנייה אחת ו־פריט היסטוריה אחד מוכנים לייבוא לפרופיל Work.")
  #expect(
    readable(
      BrowserImportPreviewCounts.summary(
        bookmarks: 2, history: 2, profileName: "Work", language: .hebrew))
      == "שתי סימניות ו־שני פריטי היסטוריה מוכנים לייבוא לפרופיל Work.")
}

@MainActor @Test func browserImportPreviewTitleIsVoiceOverHeading() {
  #expect(BrowserImportPreviewView.headingTraits == .isHeader)
}

@Test func browserImportPreviewCountBenchmark() {
  let items = (0..<50_000).map { index in
    BrowserImportItem(
      kind: index.isMultiple(of: 2) ? .bookmark : .history,
      title: "Item \(index)", address: "https://example.com/\(index)")
  }
  let filterStart = ContinuousClock.now
  var filterCount = 0
  for _ in 0..<10 {
    filterCount += items.filter { $0.kind == .bookmark }.count
    filterCount += items.filter { $0.kind == .history }.count
  }
  let filterDuration = filterStart.duration(to: .now)
  let reduceStart = ContinuousClock.now
  var reduceCount = 0
  for _ in 0..<10 {
    let counts = BrowserImportPreviewCounts.count(items)
    reduceCount += counts.bookmarks + counts.history
  }
  let reduceDuration = reduceStart.duration(to: .now)
  print("browserImportPreviewCountBenchmark: filters=\(filterDuration), reduce=\(reduceDuration)")
  #expect(filterCount == reduceCount && reduceCount == 500_000)
}

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
