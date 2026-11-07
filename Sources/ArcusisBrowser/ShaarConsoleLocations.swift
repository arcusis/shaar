// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarConsoleLocation: Equatable, Sendable {
  let url: String
  let line: Int
  let column: Int

  var source: String { "\(url):\(line):\(column)" }
}

/// Locations carried in console text. shaar.20 projects the message, and an
/// Error description includes the V8 stack. A newer engine may also send
/// native frames; this parser covers the pinned engine when that list is empty.
enum ShaarConsoleLocations {
  static func frames(in message: String) -> [ShaarConsoleFrame] {
    var frames: [ShaarConsoleFrame] = []
    for raw in message.split(separator: "\n", omittingEmptySubsequences: false) {
      guard let frame = frame(from: raw.trimmingCharacters(in: .whitespaces)) else { continue }
      frames.append(frame)
      if frames.count == 20 { break }
    }
    return frames
  }

  /// `http(s)://host[:port]/path:line:column`. The line and column are the
  /// trailing numeric fields, so a port stays on the URL. A path is required,
  /// which keeps editor paths such as `/app/main.ts:8` out of this parser.
  static func parse(_ source: String) -> ShaarConsoleLocation? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
    guard let columnColon = trimmed.lastIndex(of: ":") else { return nil }
    let columnText = trimmed[trimmed.index(after: columnColon)...]
    guard let column = positiveInteger(String(columnText)) else { return nil }
    let head = trimmed[..<columnColon]
    if let lineColon = head.lastIndex(of: ":") {
      let lineText = head[head.index(after: lineColon)...]
      let url = String(head[..<lineColon])
      if let line = positiveInteger(String(lineText)), webResource(url) {
        return ShaarConsoleLocation(url: url, line: line, column: column)
      }
    }
    let url = String(head)
    guard webResource(url) else { return nil }
    return ShaarConsoleLocation(url: url, line: column, column: 1)
  }

  private static func frame(from line: String) -> ShaarConsoleFrame? {
    guard line.hasPrefix("at ") else { return nil }
    let body = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    if body.hasSuffix(")"), let open = body.lastIndex(of: "("),
      open < body.index(before: body.endIndex)
    {
      let inside = body[body.index(after: open)..<body.index(before: body.endIndex)]
      guard let location = parse(String(inside)) else { return nil }
      let function = body[..<open].trimmingCharacters(in: .whitespaces)
      let name = function.isEmpty ? "(anonymous)" : function
      return ShaarConsoleFrame(function: name, source: location.source)
    }
    guard let location = parse(body) else { return nil }
    return ShaarConsoleFrame(function: "(anonymous)", source: location.source)
  }

  private static func positiveInteger(_ text: String) -> Int? {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    guard let value = Int(text), value > 0 else { return nil }
    return value
  }

  private static func webResource(_ url: String) -> Bool {
    guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
    guard let scheme = url.range(of: "://") else { return false }
    return url[scheme.upperBound...].contains("/")
  }
}
