// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SnapshotSaveSchedulerTests {
  @Test func rapidSnapshotsCoalesceAndImmediateSaveSupersedesPending() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let scheduler = SnapshotSaveScheduler()
    for value in ["first", "second", "latest"] {
      scheduler.schedule(
        {
          let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
          try Data((previous + value).utf8).write(to: url)
        },
        completion: { _ in })
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(try String(contentsOf: url, encoding: .utf8) == "latest")

    scheduler.schedule({ try Data("stale".utf8).write(to: url) }, completion: { _ in })
    try scheduler.writeNow { try Data("flushed".utf8).write(to: url) }
    try await Task.sleep(for: .milliseconds(350))
    #expect(try String(contentsOf: url, encoding: .utf8) == "flushed")
  }
}
