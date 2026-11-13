// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test @MainActor func browserImportMainActorReadFocusedBenchmark() async throws {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "shaar-import-benchmark-\(UUID().uuidString).html")
  defer { try? FileManager.default.removeItem(at: url) }
  let bookmarks = (0..<10_000).map { index in
    "<DT><A HREF=\"https://example-\(index).test/\">Bookmark \(index)</A>"
  }.joined(separator: "\n")
  try Data(bookmarks.utf8).write(to: url)

  let start = ContinuousClock.now
  let heartbeat = Task { @MainActor in ContinuousClock.now }
  let batch = try await BrowserImport.readOffMain(url, source: .chrome)
  let heartbeatTime = await heartbeat.value
  print("browserImportMainActorReadFocusedBenchmark: \(start.duration(to: heartbeatTime))")
  #expect(batch.items.count == 10_000)
}
