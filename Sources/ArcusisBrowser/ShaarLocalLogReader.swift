// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarLocalLogReader {
  private struct FileIdentity: Equatable {
    let system: UInt64
    let file: UInt64
  }

  let file: URL
  private var fileIdentity: FileIdentity?
  private var offset: UInt64 = 0
  private var pending = ""

  init(file: URL) { self.file = file }

  mutating func readLines() throws -> [String] {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else {
      if !FileManager.default.fileExists(atPath: file.path) {
        fileIdentity = nil
        offset = 0
        pending = ""
      }
      return []
    }
    let identity: FileIdentity? = {
      guard let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
      else { return nil }
      return FileIdentity(system: system, file: file)
    }()
    if let fileIdentity, let identity, fileIdentity != identity {
      offset = 0
      pending = ""
    }
    fileIdentity = identity
    if size < offset {
      offset = 0
      pending = ""
    }
    let start = max(offset, size > 128_000 ? size - 128_000 : 0)
    let skipped = start > offset
    if skipped { pending = "" }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: start)
    let data = try handle.read(upToCount: 128_000) ?? Data()
    offset = start + UInt64(data.count)
    var text = String(decoding: data, as: UTF8.self)
    if skipped, let newline = text.firstIndex(of: "\n") {
      text = String(text[text.index(after: newline)...])
    }
    let combined = pending + text
    var parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    pending = combined.hasSuffix("\n") ? "" : String(parts.removeLast().suffix(4_096))
    if combined.hasSuffix("\n") { parts.removeLast() }
    return parts.suffix(80).map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
  }
}
