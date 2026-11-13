// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct SessionRecoveryPhaseTests {
  @Test func openRejectsUnknownPhaseBeforeInspectingRestartFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "session-recovery-phase-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try SessionRecoveryProbe.open(
        root: root, fixture: URL(string: "http://127.0.0.1:48123")!, phase: "unexpected")
      Issue.record("Unknown recovery phase was accepted.")
    } catch {
      #expect(error.localizedDescription == "Session-recovery phase must be initial or restart.")
    }
  }
}
