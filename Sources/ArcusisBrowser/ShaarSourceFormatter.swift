// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarSourceKind: Equatable {
  case json
  case script
  case style
}

enum ShaarSourceFormatter {
  static let maximumBytes = 512 * 1_024

  static func format(_ source: String, kind: ShaarSourceKind) -> String {
    guard source.utf8.count <= maximumBytes else { return source }
    switch kind {
    case .json:
      return json(source) ?? source
    case .script, .style:
      return layout(source)
    }
  }

  static func json(_ source: String) -> String? {
    guard let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let formatted = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    else { return nil }
    return String(data: formatted, encoding: .utf8)
  }

  /// Inserts breaks after braces and after semicolons that are outside
  /// parentheses, strings, and comments. Regex literals are not detected.
  static func layout(_ source: String) -> String {
    var result = ""
    var depth = 0
    var parentheses = 0
    var quote: Character?
    var escaped = false
    var index = source.startIndex
    while index < source.endIndex {
      let character = source[index]
      let next = source.index(after: index)
      if let open = quote {
        result.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == open {
          quote = nil
        }
        index = next
        continue
      }
      if character == "/" && next < source.endIndex && source[next] == "/" {
        copyLineComment(source, from: &index, into: &result)
        continue
      }
      if character == "/" && next < source.endIndex && source[next] == "*" {
        copyBlockComment(source, from: &index, into: &result)
        continue
      }
      if character == "\"" || character == "'" || character == "`" {
        quote = character
        escaped = false
        result.append(character)
        index = next
        continue
      }
      if character == "(" {
        parentheses += 1
        result.append(character)
        index = next
        continue
      }
      if character == ")" {
        parentheses = max(0, parentheses - 1)
        result.append(character)
        index = next
        continue
      }
      if character == "{" {
        result.append(character)
        depth += 1
        breakLine(&result, depth: depth)
        index = next
        continue
      }
      if character == "}" {
        depth = max(0, depth - 1)
        breakLine(&result, depth: depth)
        result.append(character)
        index = next
        continue
      }
      if character == ";" && parentheses == 0 {
        result.append(character)
        breakLine(&result, depth: depth)
        index = next
        continue
      }
      if character == "\n" || character == "\r" {
        if !endsLine(result) { breakLine(&result, depth: depth) }
        index = next
        continue
      }
      if character == " " || character == "\t" {
        if let last = result.last, last != " ", last != "\n" { result.append(" ") }
        index = next
        continue
      }
      result.append(character)
      index = next
    }
    while result.last == " " || result.last == "\n" { result.removeLast() }
    if result.isEmpty { return source }
    return result + "\n"
  }

  private static func copyLineComment(
    _ source: String, from index: inout String.Index, into result: inout String
  ) {
    while index < source.endIndex && source[index] != "\n" {
      result.append(source[index])
      index = source.index(after: index)
    }
  }

  private static func copyBlockComment(
    _ source: String, from index: inout String.Index, into result: inout String
  ) {
    result.append(source[index])
    index = source.index(after: index)
    if index < source.endIndex {
      result.append(source[index])
      index = source.index(after: index)
    }
    while index < source.endIndex {
      let character = source[index]
      result.append(character)
      index = source.index(after: index)
      if character == "*", index < source.endIndex, source[index] == "/" {
        result.append(source[index])
        index = source.index(after: index)
        return
      }
    }
  }

  private static func breakLine(_ result: inout String, depth: Int) {
    while result.last == " " { result.removeLast() }
    if !result.isEmpty && !result.hasSuffix("\n") { result.append("\n") }
    if depth > 0 { result.append(String(repeating: "  ", count: depth)) }
  }

  private static func endsLine(_ result: String) -> Bool {
    var end = result.endIndex
    while end > result.startIndex {
      let previous = result.index(before: end)
      if result[previous] == " " {
        end = previous
        continue
      }
      return result[previous] == "\n"
    }
    return false
  }
}
