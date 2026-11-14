import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadsPanelTests {
  @Test func titleExposesHeadingTrait() {
    #expect(DownloadsPanelAccessibility.titleTraits.contains(.isHeader))
  }

  @Test func emptyProfileShowsDownloadsEmptyState() throws {
    let store = BrowserStore()
    let profileID = try #require(store.session.profiles.first?.id)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCShaarRuntime()),
      windowID: "downloads-panel-test", store: store)
    let imageURL = FileManager.default.temporaryDirectory.appending(
      path: "downloads-panel-empty-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: imageURL) }

    _ = try VisualCapture.renderOffscreen(
      DownloadsPanel(store: store, engine: engine, profileID: profileID),
      size: NSSize(width: 560, height: 440), appearance: .aqua, to: imageURL)
    let lines = try VisualTextRecognition.lines(in: imageURL).map { $0.lowercased() }

    #expect(lines.contains { $0.contains("no downloads") })
    #expect(lines.contains { $0.contains("downloads for this profile appear here") })
  }
}
