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
  private static let maximumIndentationDepth = 32
  private static let regexPrefixWords: Set<String> = [
    "return", "throw", "case", "delete", "void", "typeof", "instanceof",
    "in", "of", "yield", "await", "else", "do",
  ]
  private static let controlWords: Set<String> = ["if", "while", "for", "with", "switch", "catch"]

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

  /// Inserts breaks after braces and after semicolons outside parentheses,
  /// strings, comments, and regular-expression literals.
  static func layout(_ source: String) -> String {
    var result = ""
    var depth = 0
    var parentheses = 0
    var controlParentheses: [Bool] = []
    var precedingControlWord = false
    var quote: Character?
    var escaped = false
    var canStartRegex = true
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
          canStartRegex = false
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
      if character == "/" && canStartRegex,
        copyRegexLiteral(source, from: &index, into: &result)
      {
        canStartRegex = false
        continue
      }
      if character == "\"" || character == "'" || character == "`" {
        precedingControlWord = false
        quote = character
        escaped = false
        result.append(character)
        index = next
        continue
      }
      if character.isLetter || character == "_" || character == "$" {
        let word = copyIdentifier(source, from: &index, into: &result)
        canStartRegex = regexFollows(word)
        precedingControlWord = controlWords.contains(word)
        continue
      }
      if character.isNumber {
        canStartRegex = false
        precedingControlWord = false
        result.append(character)
        index = next
        continue
      }
      if character == "(" {
        parentheses += 1
        controlParentheses.append(precedingControlWord)
        precedingControlWord = false
        canStartRegex = true
        result.append(character)
        index = next
        continue
      }
      if character == ")" {
        parentheses = max(0, parentheses - 1)
        canStartRegex = controlParentheses.popLast() ?? false
        precedingControlWord = false
        result.append(character)
        index = next
        continue
      }
      if character == "{" {
        precedingControlWord = false
        canStartRegex = true
        result.append(character)
        depth += 1
        breakLine(&result, depth: depth)
        index = next
        continue
      }
      if character == "}" {
        precedingControlWord = false
        depth = max(0, depth - 1)
        canStartRegex = false
        breakLine(&result, depth: depth)
        result.append(character)
        index = next
        continue
      }
      if character == ";" && parentheses == 0 {
        precedingControlWord = false
        canStartRegex = true
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
      precedingControlWord = false
      if "[,:;!?=+-*%&|^~<>".contains(character) {
        canStartRegex = true
      } else if character == "]" || character == "." {
        canStartRegex = false
      }
      result.append(character)
      index = next
    }
    while result.last == " " || result.last == "\n" { result.removeLast() }
    if result.isEmpty { return source }
    return result + "\n"
  }

  private static func regexFollows(_ word: String) -> Bool {
    regexPrefixWords.contains(word)
  }

  private static func copyIdentifier(
    _ source: String, from index: inout String.Index, into result: inout String
  ) -> String {
    var word = ""
    while index < source.endIndex {
      let character = source[index]
      guard character.isLetter || character.isNumber || character == "_" || character == "$"
      else { break }
      word.append(character)
      result.append(character)
      index = source.index(after: index)
    }
    return word
  }

  private static func copyRegexLiteral(
    _ source: String, from index: inout String.Index, into result: inout String
  ) -> Bool {
    var cursor = source.index(after: index)
    var escaped = false
    var inClass = false
    while cursor < source.endIndex {
      let character = source[cursor]
      if character == "\n" || character == "\r" { return false }
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "[" {
        inClass = true
      } else if character == "]" {
        inClass = false
      } else if character == "/" && !inClass {
        cursor = source.index(after: cursor)
        while cursor < source.endIndex && source[cursor].isLetter {
          cursor = source.index(after: cursor)
        }
        result.append(contentsOf: source[index..<cursor])
        index = cursor
        return true
      }
      cursor = source.index(after: cursor)
    }
    return false
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
    if depth > 0 {
      result.append(String(repeating: "  ", count: min(depth, maximumIndentationDepth)))
    }
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
