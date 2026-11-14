// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func localLogReaderStartsAtTheBeginningAfterAtomicReplacement() throws {
  let file = FileManager.default.temporaryDirectory
    .appendingPathComponent("shaar-local-log-atomic-\(UUID().uuidString).log")
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("old line\n".utf8).write(to: file)
  var reader = ShaarLocalLogReader(file: file)
  #expect(try reader.readLines() == ["old line"])

  let replacement = "replacement begins before the old offset\nnext line\n"
  try Data(replacement.utf8).write(to: file, options: .atomic)

  #expect(try reader.readLines() == ["replacement begins before the old offset", "next line"])
}
