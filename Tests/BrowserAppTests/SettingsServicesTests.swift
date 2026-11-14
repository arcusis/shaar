// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SettingsServicesTests {
  @Test func historyClearDeletesEveryDistinctURLAcrossBatches() async throws {
    let runtime = HistoryClearRuntime(rows: [
      ["url": "https://one.example/"], ["url": "https://one.example/"],
      ["url": "https://two.example/"],
    ])
    let profileID = UUID()

    try await SettingsHistory.clear(runtime: runtime, profileID: profileID)

    #expect(runtime.requestedProfiles == [profileID.uuidString, profileID.uuidString])
    #expect(runtime.requestedLimits == [500, 500])
    #expect(Set(runtime.deletedURLs) == ["https://one.example/", "https://two.example/"])
    #expect(runtime.deletedProfiles == [profileID.uuidString, profileID.uuidString])
  }

  @Test func historyClearRejectsMalformedRowsBeforeDeletingAnything() async {
    let runtime = HistoryClearRuntime(rows: [["title": "No URL"]])

    await #expect(throws: (any Error).self) {
      try await SettingsHistory.clear(runtime: runtime, profileID: UUID())
    }

    #expect(runtime.deletedURLs.isEmpty)
  }
}

@Test @MainActor func browserSettingsAppearanceMapsKnownAndUnknownValues() {
  let app = NSApplication.shared
  let original = app.appearance
  defer { app.appearance = original }

  BrowserSettingsAppearance.apply("light")
  #expect(app.appearance?.name == .aqua)
  BrowserSettingsAppearance.apply("dark")
  #expect(app.appearance?.name == .darkAqua)
  BrowserSettingsAppearance.apply("system")
  #expect(app.appearance == nil)
}

@MainActor
private final class HistoryClearRuntime: ARCChromiumRuntime {
  private var rows: [[AnyHashable: Any]]
  var requestedProfiles: [String] = []
  var requestedLimits: [Int] = []
  var deletedURLs: [String] = []
  var deletedProfiles: [String] = []

  init(rows: [[AnyHashable: Any]]) {
    self.rows = rows
    super.init()
  }

  override func history(
    forProfileID profileID: String, limit: Int,
    completion: @escaping @MainActor @Sendable ([[AnyHashable: Any]]?, Error?) -> Void
  ) {
    requestedProfiles.append(profileID)
    requestedLimits.append(limit)
    completion(rows, nil)
  }

  override func deleteHistoryURL(
    _ url: String, profileID: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    deletedURLs.append(url)
    deletedProfiles.append(profileID)
    rows.removeAll { $0["url"] as? String == url }
    completion(nil)
  }
}

@Test @MainActor func settingsHistoryDeletesEveryBatchUntilTheStoreIsEmpty() async throws {
  let runtime = SettingsHistoryTestRuntime(batches: [
    [["url": "https://example.com/one"], ["url": "https://example.com/two"]],
    [["url": "https://example.com/three"]],
    [],
  ])
  let profileID = UUID()

  try await SettingsHistory.clear(runtime: runtime, profileID: profileID)

  #expect(
    Set(runtime.deletedURLs) == [
      "https://example.com/one", "https://example.com/two", "https://example.com/three",
    ])
  #expect(runtime.requestedLimits == [500, 500, 500])
  #expect(runtime.requestedProfiles == Array(repeating: profileID.uuidString, count: 3))
}

@Test @MainActor func settingsHistoryStopsWhenTheSameBatchRepeats() async {
  let rows: [[String: Any]] = [["url": "https://example.com/one"]]
  let runtime = SettingsHistoryTestRuntime(batches: [rows, rows])

  do {
    try await SettingsHistory.clear(runtime: runtime, profileID: UUID())
    Issue.record("Expected repeated history rows to stop clearing")
  } catch let error as CocoaError {
    #expect(error.code == .fileWriteUnknown)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
  #expect(runtime.deletedURLs == ["https://example.com/one"])
}

@Test @MainActor func settingsHistoryRejectsRowsWithoutURLs() async {
  let runtime = SettingsHistoryTestRuntime(batches: [[["title": "missing URL"]]])

  do {
    try await SettingsHistory.clear(runtime: runtime, profileID: UUID())
    Issue.record("Expected a history row without a URL to be rejected")
  } catch let error as CocoaError {
    #expect(error.code == .coderInvalidValue)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
  #expect(runtime.deletedURLs.isEmpty)
}

@MainActor
private final class SettingsHistoryTestRuntime: ARCChromiumRuntime {
  var batches: [[[AnyHashable: Any]]]
  var deletedURLs: [String] = []
  var requestedLimits: [Int] = []
  var requestedProfiles: [String] = []

  init(batches: [[[AnyHashable: Any]]]) {
    self.batches = batches
    super.init()
  }

  override func history(
    forProfileID profileID: String, limit: Int,
    completion: @escaping @MainActor @Sendable ([[AnyHashable: Any]]?, Error?) -> Void
  ) {
    requestedProfiles.append(profileID)
    requestedLimits.append(limit)
    completion(batches.isEmpty ? [] : batches.removeFirst(), nil)
  }

  override func deleteHistoryURL(
    _ url: String, profileID: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    deletedURLs.append(url)
    completion(nil)
  }
}
