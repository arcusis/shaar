// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

private final class SiteTargetRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var pictureInPictureChanges: [String] = []
  override func windowID(forTabID tabID: String) -> String? { "site-target-window" }
  override func setAutoPictureInPictureAllowed(_ allowed: Bool, tabID: String) {
    pictureInPictureChanges.append(tabID)
  }
}

@MainActor @Test func staleSiteControlTargetCannotChangeOldSitePreference() async throws {
  let oldURL = try #require(URL(string: "https://old.example/watch"))
  let newURL = try #require(URL(string: "https://new.example/watch"))
  let tab = BrowserTab(url: newURL)
  let profile = BrowserProfile(name: "Site controls")
  let space = BrowserSpace(
    profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
    tabs: [tab], selectedTabID: tab.id)
  let session = try BrowserSession(
    profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  let store = BrowserStore(session: session)
  let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
  defer { try? FileManager.default.removeItem(at: file) }
  store.usePreferences(BrowserPreferencesStore(fileURL: file))
  let runtime = SiteTargetRuntime()
  let engine = try BrowserEngine(
    events: BrowserRuntimeEvents(runtime: runtime), windowID: "site-target-window",
    store: store)
  defer { engine.suspensionTask?.cancel() }
  engine.liveTabs.insert(tab.id)
  let stale = SiteControlTarget(tabID: tab.id, profileID: profile.id, url: oldURL)

  #expect(engine.siteControlTarget?.url == newURL)
  #expect(store.automaticPictureInPictureAllowed(for: oldURL, profileID: profile.id))
  await #expect(throws: (any Error).self) {
    try await engine.setPermission(.autoPictureInPicture, allowed: false, for: stale)
  }
  #expect(store.automaticPictureInPictureAllowed(for: oldURL, profileID: profile.id))

  let current = try #require(engine.siteControlTarget)
  #expect(runtime.pictureInPictureChanges.isEmpty)
  try await engine.setPermission(.autoPictureInPicture, allowed: false, for: current)
  #expect(!store.automaticPictureInPictureAllowed(for: newURL, profileID: profile.id))
  #expect(runtime.pictureInPictureChanges == [tab.id.uuidString])
}
