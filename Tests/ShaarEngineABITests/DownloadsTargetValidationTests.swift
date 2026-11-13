// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@Test func downloadTargetMustBeAFileBelowTheEffectiveDirectory() throws {
  let adapter = ShaarDownloadsAdapter(transport: EmptyDownloadsTransport())
  let root = URL(fileURLWithPath: "/tmp/Downloads")
  for path in ["/tmp/Downloads", "/tmp/Downloads-evil/file.bin"] {
    let record = ShaarDownloadRecord(
      id: "id", url: "https://example.test/file.bin", filename: "file.bin", path: path,
      state: .finished, paused: false, received: 1, total: 1, speed: 0,
      mimeType: "application/octet-stream", dangerous: false, offTheRecord: false,
      error: nil, startTime: 0)
    #expect(throws: ShaarDownloadsError.unsafeTarget) {
      try adapter.validatedTarget(for: record, effectiveDirectory: root)
    }
  }
}

private struct EmptyDownloadsTransport: ShaarDownloadsTransport {
  func submit(operation: UInt32, arguments: Data) async throws -> Data { Data() }
}
