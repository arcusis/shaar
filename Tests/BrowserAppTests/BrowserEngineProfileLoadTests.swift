// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineProfileLoadTests {
  @Test func staleDirectoryAcknowledgementDoesNotReplaceLatestPreference() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let requested = root.appending(path: "Requested", directoryHint: .isDirectory)
    let latest = root.appending(path: "Latest", directoryHint: .isDirectory)
    let acknowledged = root.appending(path: "EngineResolved", directoryHint: .isDirectory)
    for directory in [requested, latest, acknowledged] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    store.preferences.setDownloadDirectory(latest, for: profile)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), windowID: "profile-load-window",
      store: store)

    engine.recordDownloadDirectoryAcknowledgement(acknowledged, requested: requested, for: profile)

    #expect(store.preferences.downloadDirectory(for: profile) == latest)
  }
  @Test func profileLoadFailureUsesLocalizedRecoveryNotice() async throws {
    let store = BrowserStore()
    let runtime = ProfileLoadFailureRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime),
      windowID: "profile-load-failure-window", store: store)
    defer { engine.suspensionTask?.cancel() }

    engine.reconcile()
    for _ in 0..<100 {
      if engine.notice != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(engine.notice == ShellL10n.string("Could not load this profile. Try again."))
  }
}

@MainActor
private final class ProfileLoadFailureRuntime: ARCChromiumRuntime {
  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(
      NSError(
        domain: "ProfileLoadFailureTest", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Raw engine profile error."]))
  }
}
