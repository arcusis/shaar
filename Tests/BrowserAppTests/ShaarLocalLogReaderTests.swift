// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func localLogReaderJoinsPartialLinesAcrossReads() throws {
  let file = temporaryLogFile()
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("first\npart".utf8).write(to: file)
  var reader = ShaarLocalLogReader(file: file)

  #expect(try reader.readLines() == ["first"])
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("ial\nsecond\n".utf8))
  try handle.close()

  #expect(try reader.readLines() == ["partial", "second"])
}

@Test func localLogReaderResetsItsOffsetWhenTheFileShrinks() throws {
  let file = temporaryLogFile()
  defer { try? FileManager.default.removeItem(at: file) }
  try Data("previous contents\n".utf8).write(to: file)
  var reader = ShaarLocalLogReader(file: file)
  #expect(try reader.readLines() == ["previous contents"])

  try Data("new\n".utf8).write(to: file)
  #expect(try reader.readLines() == ["new"])
}

private func temporaryLogFile() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("shaar-local-log-\(UUID().uuidString).log")
}
