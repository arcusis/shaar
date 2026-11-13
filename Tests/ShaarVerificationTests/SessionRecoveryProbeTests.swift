// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct SessionRecoveryProbeTests {
  @Test func initialPhaseAuthorsTheExpectedProfileAndTabFixture() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "session-recovery-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = URL(string: "http://127.0.0.1:48123")!

    let probe = try SessionRecoveryProbe.open(root: root, fixture: fixture, phase: "initial")
    let session = probe.store.session
    #expect(session.profiles.count == 2)
    #expect(session.spaces.map(\.name) == ["Recovery alpha", "Recovery beta", "Recovery shared"])
    #expect(session.spaces.map { $0.tabs.count } == [2, 1, 1])
    #expect(session.selectedSpace.name == "Recovery alpha")
    #expect(session.selectedSpace.selectedTab?.url == fixture.appending(path: "recovery-today"))

    let alpha = session.spaces[0]
    let beta = session.spaces[1]
    let shared = session.spaces[2]
    #expect(alpha.tabs[0].isPinned)
    #expect(alpha.tabs[0].folderID == alpha.folders.first?.id)
    #expect(beta.profileID != alpha.profileID)
    #expect(shared.profileID == alpha.profileID)
    #expect(session.favorites.map(\.title) == ["Recovery favorite"])
    #expect(session.favorites.first?.profileID == alpha.profileID)
  }
}
