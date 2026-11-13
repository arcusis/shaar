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
