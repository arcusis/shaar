// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct SessionRecoveryRestartTests {
  @Test func restartOpensThePersistedWorkspaceAfterTheKillCheckpoint() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "session-recovery-restart-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = URL(string: "http://127.0.0.1:48123")!

    let initial = try SessionRecoveryProbe.open(root: root, fixture: fixture, phase: "initial")
    #expect(initial.workspace.persistSnapshot())
    let expected = initial.workspace.workspace

    let restarted = try SessionRecoveryProbe.open(root: root, fixture: fixture, phase: "restart")
    #expect(restarted.workspace.storageNotice == nil)
    #expect(restarted.workspace.workspace == expected)
    #expect(restarted.store.session == initial.store.session)
  }
}
