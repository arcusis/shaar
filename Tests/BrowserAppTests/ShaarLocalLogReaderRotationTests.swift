// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func localLogReaderStartsAtTheBeginningAfterTheFileIsRecreated() throws {
  let file = FileManager.default.temporaryDirectory
    .appendingPathComponent("shaar-local-log-rotation-\(UUID().uuidString).log")
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("old\n".utf8).write(to: file)
  var reader = ShaarLocalLogReader(file: file)
  #expect(try reader.readLines() == ["old"])

  try FileManager.default.removeItem(at: file)
  #expect(try reader.readLines().isEmpty)
  try Data("new first line\nnew second line\n".utf8).write(to: file)

  #expect(try reader.readLines() == ["new first line", "new second line"])
}
