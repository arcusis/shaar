// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import BrowserTestSupport
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct PreferencesPropertyTests {
  @Test(arguments: [1, 2])
  func committedPreferencesPreserveSettingsAndMigrate(version: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "preferences.json")
    let original = try Data(contentsOf: UpgradeFixtures.url("preferences-v\(version)"))
    try original.write(to: file)
    let store = BrowserPreferencesStore(fileURL: file)
    #expect(store.storageNotice == nil)
    #expect(!store.sidebarInitiallyVisible)
    #expect(store.searchEngine(for: UpgradeFixtures.profileID) == .bing)
    #expect(try Data(contentsOf: file) == original)
    store.setSidebarInitiallyVisible(true)
    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.sidebarInitiallyVisible)
    #expect(reloaded.searchEngine(for: UpgradeFixtures.profileID) == .bing)
    if version == 2 {
      #expect(
        reloaded.pinnedExtensionIDs(for: UpgradeFixtures.profileID) == [
          String(repeating: "a", count: 32)
        ])
      #expect(
        reloaded.accounts(for: UpgradeFixtures.profileID).map(\.email) == [
          "fixture@example.invalid"
        ])
    }
  }

  @Test(arguments: SeededGenerator.seeds)
  func seededPreferencesRoundTripAndPreserveRejectedFiles(seed: UInt64) throws {
    var random = SeededGenerator(seed: seed)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<32 {
      let context = "seed=\(seed), case=\(index)"
      let profile = random.identifier()
      let engine = BrowserSearchEngine.allCases[random.sample(BrowserSearchEngine.allCases.count)]
      let visible = random.sample(2) == 0
      let unknown = index % 4 == 0
      var payload: [String: Any] = [
        "version": 1 + random.sample(2), "sidebarInitiallyVisible": visible,
        "profileSearchEngines": [
          profile.uuidString, unknown ? "future-\(random.next())" : engine.rawValue,
        ],
      ]
      let file = directory.appending(path: "case-\(index).json")
      try JSONSerialization.data(withJSONObject: payload).write(to: file)
      let store = BrowserPreferencesStore(fileURL: file)
      #expect(store.storageNotice == nil, "\(context)")
      #expect(store.sidebarInitiallyVisible == visible, "\(context)")
      #expect(store.searchEngine(for: profile) == (unknown ? .google : engine), "\(context)")
      store.setSidebarInitiallyVisible(!visible)
      #expect(
        BrowserPreferencesStore(fileURL: file).searchEngine(for: profile)
          == (unknown ? .google : engine), "\(context)")
      payload["version"] = 3 + random.sample(100)
      if index % 2 == 0 { payload["sidebarInitiallyVisible"] = "invalid-\(random.next())" }
      let rejected = try JSONSerialization.data(withJSONObject: payload)
      try rejected.write(to: file)
      let invalid = BrowserPreferencesStore(fileURL: file)
      #expect(invalid.storageNotice != nil, "\(context)")
      invalid.setSidebarInitiallyVisible(visible)
      invalid.setSearchEngine(engine, for: profile)
      #expect(try Data(contentsOf: file) == rejected, "\(context)")
    }
  }
}
