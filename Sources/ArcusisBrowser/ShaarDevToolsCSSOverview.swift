// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarDevToolsCSSSheet: Equatable, Sendable {
  var name: String
  var url: String
  var text: String
}

struct ShaarLoadedStylesheets: Equatable, Sendable {
  var sheets: [ShaarDevToolsCSSSheet]
  var clipped: Bool
}

struct ShaarDevToolsCSSItem: Equatable, Identifiable, Sendable {
  var label: String
  var count: Int
  var sheets: [String]
  var id: String { label }
}

struct ShaarDevToolsCSSPaint: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

enum ShaarDevToolsCSSPick: Equatable, Sendable {
  case color(String)
  case font(String)
}

struct ShaarDevToolsCSSSummary: Equatable, Sendable {
  var colors: [ShaarDevToolsCSSItem]
  var fonts: [ShaarDevToolsCSSItem]
  var media: [ShaarDevToolsCSSItem]
  var examined: Int
  var clipped: Bool

  static let empty = ShaarDevToolsCSSSummary(
    colors: [], fonts: [], media: [], examined: 0, clipped: false)

  var isEmpty: Bool { colors.isEmpty && fonts.isEmpty && media.isEmpty }

  var contributingSheets: [String] {
    var seen: [String] = []
    for item in colors + fonts + media {
      for sheet in item.sheets where !seen.contains(sheet) {
        seen.append(sheet)
      }
    }
    return seen
  }

  func sheets(matching pick: ShaarDevToolsCSSPick) -> [String] {
    let label: String
    let items: [ShaarDevToolsCSSItem]
    switch pick {
    case .color(let value):
      label = value
      items = colors
    case .font(let value):
      label = value
      items = fonts
    }
    return items.first { $0.label == label }?.sheets ?? []
  }
}

enum ShaarDevToolsCSSOverview {
  static let maximumSheets = 32
  static let maximumTextBytes = 512 * 1_024

  static func isStylesheet(type: String, mimeType: String, url: String) -> Bool {
    if type.caseInsensitiveCompare("Stylesheet") == .orderedSame { return true }
    if mimeType.range(of: "css", options: .caseInsensitive) != nil { return true }
    let path = URLComponents(string: url)?.path ?? url
    return path.lowercased().hasSuffix(".css")
  }

  static func isLoadableSheetURL(_ url: String) -> Bool {
    guard let parts = URLComponents(string: url) else { return false }
    let scheme = parts.scheme?.lowercased() ?? ""
    return (scheme == "http" || scheme == "https") && parts.host != nil
  }

  static func clipped(_ text: String) -> (text: String, clipped: Bool) {
    guard text.utf8.count > maximumTextBytes else { return (text, false) }
    let bytes = text.utf8.prefix(maximumTextBytes)
    return (String(decoding: bytes, as: UTF8.self), true)
  }

  static func summarize(_ sheets: [ShaarDevToolsCSSSheet]) -> ShaarDevToolsCSSSummary {
    let labels = displayLabels(sheets)
    var colorTallies: [String: Tally] = [:]
    var fontTallies: [String: Tally] = [:]
    var mediaTallies: [String: Tally] = [:]
    for (sheet, label) in zip(sheets, labels) {
      let scanned = scan(sheet.text)
      for declaration in scanned.declarations {
        let found = colors(in: declaration.value, named: propertyTakesColor(declaration.property))
        for color in found {
          record(color, label: color, sheet: label, into: &colorTallies)
        }
        for family in families(property: declaration.property, value: declaration.value) {
          record(family.lowercased(), label: family, sheet: label, into: &fontTallies)
        }
      }
      for query in scanned.media {
        record(query, label: query, sheet: label, into: &mediaTallies)
      }
    }
    return ShaarDevToolsCSSSummary(
      colors: ranked(colorTallies),
      fonts: ranked(fontTallies),
      media: mediaTallies.values.sorted { $0.label < $1.label }.map(\.item),
      examined: sheets.count,
      clipped: false)
  }

  static func paint(_ label: String) -> ShaarDevToolsCSSPaint? {
    if label == "transparent" { return ShaarDevToolsCSSPaint(red: 0, green: 0, blue: 0, alpha: 0) }
    if let basic = basicPaints[label] {
      return ShaarDevToolsCSSPaint(red: basic.0, green: basic.1, blue: basic.2, alpha: 1)
    }
    if label.hasPrefix("#") { return paintHex(String(label.dropFirst())) }
    if label.hasPrefix("rgb(") || label.hasPrefix("rgba(") { return paintRGB(label) }
    return nil
  }

  private struct Tally {
    var label: String
    var count = 0
    var sheets: [String] = []

    mutating func add(sheet: String) {
      count += 1
      if !sheets.contains(sheet) { sheets.append(sheet) }
    }

    var item: ShaarDevToolsCSSItem {
      ShaarDevToolsCSSItem(label: label, count: count, sheets: sheets)
    }
  }

  private struct Declaration {
    var property: String
    var value: String
  }

  private struct ScanResult {
    var declarations: [Declaration]
    var media: [String]
  }

  private static func displayLabels(_ sheets: [ShaarDevToolsCSSSheet]) -> [String] {
    let names = sheets.map { sheet -> String in
      let name = sheet.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? sheet.url : name
    }
    var counts: [String: Int] = [:]
    for name in names { counts[name, default: 0] += 1 }
    return zip(sheets, names).map { sheet, name in
      counts[name, default: 0] > 1 ? sheet.url : name
    }
  }

  private static func record(
    _ key: String, label: String, sheet: String, into tallies: inout [String: Tally]
  ) {
    var tally = tallies[key] ?? Tally(label: label)
    tally.add(sheet: sheet)
    tallies[key] = tally
  }

  private static func ranked(_ tallies: [String: Tally]) -> [ShaarDevToolsCSSItem] {
    tallies.values.sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.label < rhs.label
    }.map(\.item)
  }

  private static func scan(_ text: String) -> ScanResult {
    var declarations: [Declaration] = []
    var media: [String] = []
    var buffer = ""
    var depth = 0
    var quote: Character?
    var escaped = false
    var comment = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if comment {
        if character == "*", next < text.endIndex, text[next] == "/" {
          index = text.index(after: next)
          comment = false
          continue
        }
        index = next
        continue
      }
      if let open = quote {
        buffer.append(character)
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
      if character == "/", next < text.endIndex, text[next] == "*" {
        comment = true
        index = text.index(after: next)
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        buffer.append(character)
        index = next
        continue
      }
      if character == "{" {
        recordMedia(buffer, into: &media)
        buffer = ""
        depth += 1
        index = next
        continue
      }
      if character == "}" {
        recordDeclaration(buffer, depth: depth, into: &declarations)
        buffer = ""
        depth = max(0, depth - 1)
        index = next
        continue
      }
      if character == ";", depth >= 1 {
        recordDeclaration(buffer, depth: depth, into: &declarations)
        buffer = ""
        index = next
        continue
      }
      buffer.append(character)
      index = next
    }
    return ScanResult(declarations: declarations, media: media)
  }

  private static func recordMedia(_ buffer: String, into media: inout [String]) {
    let prelude = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard prelude.lowercased().hasPrefix("@media") else { return }
    let query = collapseWhitespace(String(prelude.dropFirst("@media".count)))
    guard !query.isEmpty else { return }
    media.append(query)
  }

  private static func recordDeclaration(
    _ buffer: String, depth: Int, into declarations: inout [Declaration]
  ) {
    guard depth >= 1, let split = splitDeclaration(buffer) else { return }
    declarations.append(split)
  }

  private static func splitDeclaration(_ raw: String) -> Declaration? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = colonOutsideStrings(in: trimmed) else { return nil }
    let property = collapseWhitespace(String(trimmed[..<colon]))
    let valueStart = trimmed.index(after: colon)
    let value = trimmed[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !property.isEmpty, !value.isEmpty, !property.contains(" "), !property.hasPrefix("@")
    else { return nil }
    return Declaration(property: property.lowercased(), value: String(value))
  }

  private static func colonOutsideStrings(in text: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if let open = quote {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == open {
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == ":" {
        return index
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func propertyTakesColor(_ property: String) -> Bool {
    if property == "color" || property.hasSuffix("-color") { return true }
    switch property {
    case "background", "border", "border-top", "border-right", "border-bottom", "border-left",
      "outline", "box-shadow", "text-shadow", "text-decoration", "column-rule", "fill", "stroke":
      return true
    default:
      return false
    }
  }

  private static func colors(in value: String, named: Bool) -> Set<String> {
    var found: Set<String> = []
    var code = ""
    func flush() {
      guard !code.isEmpty else { return }
      collectHex(code, into: &found)
      collectFunctions(code, into: &found)
      if named { collectNamed(code, into: &found) }
      code = ""
    }
    var index = value.startIndex
    while index < value.endIndex {
      let character = value[index]
      if character == "\"" || character == "'" {
        flush()
        index = endOfString(value, from: index)
        continue
      }
      if startsURL(value, at: index) {
        flush()
        index = endOfParentheses(value, from: index)
        continue
      }
      code.append(character)
      index = value.index(after: index)
    }
    flush()
    return found
  }

  private static func collectHex(_ text: String, into found: inout Set<String>) {
    let chars = Array(text)
    var index = 0
    while index < chars.count {
      let previous = index > 0 ? chars[index - 1] : nil
      if chars[index] == "#", canStartToken(previous) {
        var end = index + 1
        while end < chars.count, chars[end].isHexDigit { end += 1 }
        let length = end - (index + 1)
        if length == 3 || length == 4 || length == 6 || length == 8 {
          found.insert("#" + String(chars[(index + 1)..<end]).lowercased())
        }
        index = max(end, index + 1)
        continue
      }
      index += 1
    }
  }

  private static func collectFunctions(_ text: String, into found: inout Set<String>) {
    var index = text.startIndex
    while index < text.endIndex {
      if text[index] == "(", let name = colorFunctionName(in: text, before: index),
        let end = closingParenthesis(text, open: index)
      {
        let args = text[text.index(after: index)..<end]
        found.insert(normalizeFunction(name, args))
        index = text.index(after: end)
        continue
      }
      index = text.index(after: index)
    }
  }

  private static func collectNamed(_ text: String, into found: inout Set<String>) {
    var token = ""
    func flush() {
      let lower = token.lowercased()
      if namedColors.contains(lower) { found.insert(lower) }
      token = ""
    }
    for character in text {
      if character.isLetter {
        token.append(character)
      } else {
        flush()
      }
    }
    flush()
  }

  private static func colorFunctionName(in text: String, before paren: String.Index) -> String? {
    var start = paren
    while start > text.startIndex {
      let previous = text.index(before: start)
      if !text[previous].isLetter { break }
      start = previous
    }
    let name = text[start..<paren].lowercased()
    guard colorFunctions.contains(name) else { return nil }
    guard canStartToken(start > text.startIndex ? text[text.index(before: start)] : nil)
    else { return nil }
    return name
  }

  private static func canStartToken(_ previous: Character?) -> Bool {
    guard let previous else { return true }
    if previous.isLetter || previous.isNumber || previous == "-" || previous == "_" {
      return false
    }
    return true
  }

  private static func normalizeFunction(_ name: String, _ args: Substring) -> String {
    let dropSpaces = args.contains(",")
    var result = ""
    var pendingSpace = false
    for character in args {
      if character.isWhitespace {
        if !dropSpaces, !result.isEmpty { pendingSpace = true }
        continue
      }
      if character == "," || character == "/" {
        while result.last == " " { result.removeLast() }
        pendingSpace = false
        result.append(character)
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(character)
    }
    while result.last == " " { result.removeLast() }
    return "\(name)(\(result))"
  }

  private static func families(property: String, value: String) -> [String] {
    if property == "font-family" { return familyList(value) }
    guard property == "font", let rest = remainderAfterFontSize(value) else { return [] }
    return familyList(rest)
  }

  private static func remainderAfterFontSize(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if systemFontKeywords.contains(trimmed.lowercased()) { return trimmed }
    guard let sizeEnd = endOfFontSize(in: trimmed) else { return nil }
    var rest = trimmed[sizeEnd...]
    if rest.first == "/" {
      rest = rest.dropFirst()
      let lineEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
      rest = rest[lineEnd...]
    }
    let family = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    return family.isEmpty ? nil : family
  }

  private static func endOfFontSize(in text: String) -> String.Index? {
    var index = text.startIndex
    while index < text.endIndex {
      index = skipWhitespace(text, from: index)
      if index == text.endIndex { return nil }
      if text[index] == "\"" || text[index] == "'" {
        index = endOfString(text, from: index)
        continue
      }
      let tokenEnd = endOfBareToken(text, from: index)
      if let boundary = fontSizeBoundary(text[index..<tokenEnd]) { return boundary }
      index = tokenEnd
    }
    return nil
  }

  private static func fontSizeBoundary(_ token: Substring) -> Substring.Index? {
    let size: Substring
    let boundary: Substring.Index
    if let slash = token.firstIndex(of: "/") {
      size = token[..<slash]
      boundary = slash
    } else {
      size = token
      boundary = token.endIndex
    }
    guard isFontSize(size) else { return nil }
    return boundary
  }

  private static func isFontSize(_ token: Substring) -> Bool {
    let lower = token.lowercased()
    if fontSizeKeywords.contains(lower) { return true }
    guard let unitStart = token.firstIndex(where: { $0 != "." && !$0.isNumber }) else {
      return false
    }
    let number = token[..<unitStart]
    let unit = token[unitStart...].lowercased()
    return isCSSNumber(number) && fontSizeUnits.contains(unit)
  }

  private static func isCSSNumber(_ token: Substring) -> Bool {
    var sawDigit = false
    var sawDot = false
    for character in token {
      if character == "." {
        if sawDot { return false }
        sawDot = true
        continue
      }
      if character.isNumber {
        sawDigit = true
        continue
      }
      return false
    }
    return sawDigit
  }

  private static func familyList(_ value: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for character in value {
      if let open = quote {
        if escaped {
          escaped = false
          current.append(character)
          continue
        }
        if character == "\\" {
          escaped = true
          continue
        }
        if character == open {
          quote = nil
          continue
        }
        current.append(character)
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        continue
      }
      if character == "," {
        appendFamily(current, to: &parts)
        current = ""
        continue
      }
      current.append(character)
    }
    appendFamily(current, to: &parts)
    return parts
  }

  private static func appendFamily(_ raw: String, to parts: inout [String]) {
    let collapsed = collapseWhitespace(raw)
    guard !collapsed.isEmpty, !cssWideKeywords.contains(collapsed.lowercased()) else { return }
    parts.append(collapsed)
  }

  private static func collapseWhitespace(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func skipWhitespace(_ text: String, from index: String.Index) -> String.Index {
    var cursor = index
    while cursor < text.endIndex, text[cursor].isWhitespace {
      cursor = text.index(after: cursor)
    }
    return cursor
  }

  private static func endOfBareToken(_ text: String, from index: String.Index) -> String.Index {
    var cursor = index
    while cursor < text.endIndex, !text[cursor].isWhitespace {
      cursor = text.index(after: cursor)
    }
    return cursor
  }

  private static func endOfString(_ text: String, from index: String.Index) -> String.Index {
    let quote = text[index]
    var cursor = text.index(after: index)
    var escaped = false
    while cursor < text.endIndex {
      let character = text[cursor]
      cursor = text.index(after: cursor)
      if escaped {
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
        continue
      }
      if character == quote { return cursor }
    }
    return text.endIndex
  }

  private static func startsURL(_ text: String, at index: String.Index) -> Bool {
    let rest = text[index...].lowercased()
    guard rest.hasPrefix("url(") else { return false }
    let previous = index > text.startIndex ? text[text.index(before: index)] : nil
    return canStartToken(previous)
  }

  private static func endOfParentheses(_ text: String, from index: String.Index) -> String.Index {
    guard let open = text[index...].firstIndex(of: "(") else {
      return text.index(after: index)
    }
    guard let close = closingParenthesis(text, open: open) else { return text.endIndex }
    return text.index(after: close)
  }

  private static func closingParenthesis(_ text: String, open: String.Index) -> String.Index? {
    var depth = 0
    var quote: Character?
    var escaped = false
    var index = open
    while index < text.endIndex {
      let character = text[index]
      if let openQuote = quote {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == openQuote {
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "(" {
        depth += 1
      } else if character == ")" {
        depth -= 1
        if depth == 0 { return index }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func paintHex(_ digits: String) -> ShaarDevToolsCSSPaint? {
    let expanded: String
    switch digits.count {
    case 3, 4:
      expanded = digits.map { "\($0)\($0)" }.joined()
    case 6, 8:
      expanded = digits
    default:
      return nil
    }
    guard let red = channel(expanded, start: 0),
      let green = channel(expanded, start: 2),
      let blue = channel(expanded, start: 4)
    else { return nil }
    let alpha = expanded.count == 8 ? channel(expanded, start: 6) : 1
    guard let alpha else { return nil }
    return ShaarDevToolsCSSPaint(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func channel(_ digits: String, start: Int) -> Double? {
    let begin = digits.index(digits.startIndex, offsetBy: start)
    let end = digits.index(begin, offsetBy: 2)
    guard let value = Int(digits[begin..<end], radix: 16) else { return nil }
    return Double(value) / 255
  }

  private static func paintRGB(_ label: String) -> ShaarDevToolsCSSPaint? {
    guard let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"),
      open < close
    else { return nil }
    let args = label[label.index(after: open)..<close]
    if args.contains(",") { return paintCommaRGB(args) }
    return paintSpaceRGB(args)
  }

  private static func paintCommaRGB(_ args: Substring) -> ShaarDevToolsCSSPaint? {
    let parts = args.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count == 3 || parts.count == 4,
      let red = rgbChannel(parts[0]),
      let green = rgbChannel(parts[1]),
      let blue = rgbChannel(parts[2])
    else { return nil }
    let alpha = parts.count == 4 ? alphaChannel(parts[3]) : 1
    guard let alpha else { return nil }
    return ShaarDevToolsCSSPaint(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func paintSpaceRGB(_ args: Substring) -> ShaarDevToolsCSSPaint? {
    let pieces = args.split(whereSeparator: \.isWhitespace).map(String.init)
    let slashIndex = pieces.firstIndex(of: "/") ?? pieces.firstIndex(where: { $0.contains("/") })
    guard let slashIndex else {
      guard pieces.count == 3,
        let red = rgbChannel(pieces[0]),
        let green = rgbChannel(pieces[1]),
        let blue = rgbChannel(pieces[2])
      else { return nil }
      return ShaarDevToolsCSSPaint(red: red, green: green, blue: blue, alpha: 1)
    }
    let channels = pieces[..<slashIndex].filter { $0 != "/" }
    guard channels.count == 3,
      let red = rgbChannel(channels[0]),
      let green = rgbChannel(channels[1]),
      let blue = rgbChannel(channels[2])
    else { return nil }
    let alphaToken = alphaToken(in: pieces, slashIndex: slashIndex)
    guard let alphaToken, let alpha = alphaChannel(alphaToken) else { return nil }
    return ShaarDevToolsCSSPaint(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func alphaToken(in pieces: [String], slashIndex: Int) -> String? {
    if pieces[slashIndex] == "/" {
      guard slashIndex + 1 < pieces.count else { return nil }
      return pieces[slashIndex + 1]
    }
    return pieces[slashIndex].split(separator: "/").last.map(String.init)
  }

  private static func rgbChannel(_ token: String) -> Double? {
    if token.hasSuffix("%") {
      guard let number = Double(token.dropLast()) else { return nil }
      return min(1, max(0, number / 100))
    }
    guard let number = Double(token) else { return nil }
    return min(1, max(0, number / 255))
  }

  private static func alphaChannel(_ token: String) -> Double? {
    if token.hasSuffix("%") {
      guard let number = Double(token.dropLast()) else { return nil }
      return min(1, max(0, number / 100))
    }
    guard let number = Double(token) else { return nil }
    return min(1, max(0, number))
  }

  private static let colorFunctions: Set<String> = [
    "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color",
  ]

  private static let fontSizeKeywords: Set<String> = [
    "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large",
    "smaller", "larger", "math",
  ]

  private static let fontSizeUnits: Set<String> = [
    "px", "em", "rem", "%", "ch", "ex", "vw", "vh", "pt", "pc", "cm", "mm", "in", "q",
    "lh", "rlh", "vmin", "vmax", "cap", "ic",
  ]

  private static let systemFontKeywords: Set<String> = [
    "caption", "icon", "menu", "message-box", "small-caption", "status-bar",
  ]

  private static let cssWideKeywords: Set<String> = [
    "inherit", "initial", "unset", "revert", "revert-layer",
  ]

  private static let basicPaints: [String: (Double, Double, Double)] = [
    "black": (0, 0, 0),
    "white": (1, 1, 1),
    "red": (1, 0, 0),
    "green": (0, 128 / 255, 0),
    "lime": (0, 1, 0),
    "blue": (0, 0, 1),
    "yellow": (1, 1, 0),
    "cyan": (0, 1, 1),
    "aqua": (0, 1, 1),
    "magenta": (1, 0, 1),
    "fuchsia": (1, 0, 1),
    "gray": (128 / 255, 128 / 255, 128 / 255),
    "grey": (128 / 255, 128 / 255, 128 / 255),
    "maroon": (128 / 255, 0, 0),
    "olive": (128 / 255, 128 / 255, 0),
    "navy": (0, 0, 128 / 255),
    "purple": (128 / 255, 0, 128 / 255),
    "teal": (0, 128 / 255, 128 / 255),
    "silver": (192 / 255, 192 / 255, 192 / 255),
    "orange": (1, 165 / 255, 0),
  ]

  private static let namedColors: Set<String> = [
    "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black",
    "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
    "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue",
    "darkcyan", "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki",
    "darkmagenta", "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon",
    "darkseagreen", "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise",
    "darkviolet", "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick",
    "floralwhite", "forestgreen", "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod",
    "gray", "green", "greenyellow", "grey", "honeydew", "hotpink", "indianred", "indigo",
    "ivory", "khaki", "lavender", "lavenderblush", "lawngreen", "lemonchiffon", "lightblue",
    "lightcoral", "lightcyan", "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey",
    "lightpink", "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray",
    "lightslategrey", "lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta",
    "maroon", "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple",
    "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise",
    "mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite",
    "navy", "oldlace", "olive", "olivedrab", "orange", "orangered", "orchid", "palegoldenrod",
    "palegreen", "paleturquoise", "palevioletred", "papayawhip", "peachpuff", "peru", "pink",
    "plum", "powderblue", "purple", "rebeccapurple", "red", "rosybrown", "royalblue",
    "saddlebrown", "salmon", "sandybrown", "seagreen", "seashell", "sienna", "silver",
    "skyblue", "slateblue", "slategray", "slategrey", "snow", "springgreen", "steelblue", "tan",
    "teal", "thistle", "tomato", "transparent", "turquoise", "violet", "wheat", "white",
    "whitesmoke", "yellow", "yellowgreen", "currentcolor",
  ]
}

@MainActor @Observable
final class ShaarDevToolsCSSOverviewModel {
  private(set) var summary = ShaarDevToolsCSSSummary.empty
  private(set) var loading = false
  private(set) var loaded = false
  var failure: String?
  var pick: ShaarDevToolsCSSPick?
  @ObservationIgnored private let sources: ShaarSourcesModel
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var usingFixture = false

  init(sources: ShaarSourcesModel) {
    self.sources = sources
  }

  func reload(force: Bool = false) async {
    guard !usingFixture, !loading else { return }
    if loaded && !force { return }
    let generation = generation
    loading = true
    defer {
      if generation == self.generation { loading = false }
    }
    do {
      guard let batch = try await sources.loadStylesheets() else { return }
      guard generation == self.generation, !usingFixture else { return }
      var summary = ShaarDevToolsCSSOverview.summarize(batch.sheets)
      summary.clipped = batch.clipped
      self.summary = summary
      loaded = true
      failure = nil
      if force { pick = nil }
    } catch is CancellationError {
      return
    } catch {
      guard generation == self.generation else { return }
      failure = error.localizedDescription
    }
  }

  func present(_ sheets: [ShaarDevToolsCSSSheet]) {
    generation += 1
    usingFixture = true
    loading = false
    summary = ShaarDevToolsCSSOverview.summarize(sheets)
    loaded = true
    failure = nil
    pick = nil
  }

  func choose(_ pick: ShaarDevToolsCSSPick) {
    if self.pick == pick {
      self.pick = nil
    } else {
      self.pick = pick
    }
  }

  func reset() {
    generation += 1
    usingFixture = false
    summary = .empty
    loading = false
    loaded = false
    failure = nil
    pick = nil
  }
}

struct ShaarDevToolsCSSOverviewPanel: View {
  @Bindable var model: ShaarDevToolsModel

  var body: some View {
    let overview = model.cssOverview
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        controls
        if let failure = overview.failure {
          Text(verbatim: failure)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if overview.loaded {
          loaded(overview)
        } else {
          Text(ShellL10n.string("No style sheets loaded for this tab."))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("shaar.devtools.cssOverview")
    .task(id: model.target.tabID) {
      await model.cssOverview.reload()
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Button {
        Task { await model.cssOverview.reload(force: true) }
      } label: {
        Text(ShellL10n.string("Reload"))
      }
      .controlSize(.small)
      .disabled(model.cssOverview.loading || !model.phase2.available)
      .accessibilityIdentifier("shaar.devtools.cssReload")
      if model.cssOverview.loading {
        ProgressView().controlSize(.small)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private func loaded(_ overview: ShaarDevToolsCSSOverviewModel) -> some View {
    if overview.summary.examined == 0 {
      Text(ShellL10n.string("This page has no style sheets."))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if overview.summary.isEmpty {
      Text(
        ShellL10n.string("These style sheets declare no colors, fonts, or media queries.")
      )
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      if overview.summary.clipped {
        Text(
          ShellL10n.string(
            "Overview includes at most 32 style sheets and 512 KB of each one.")
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      if !overview.summary.colors.isEmpty {
        countSection(ShellL10n.string("Colors"), rows: colorRows(overview))
      }
      if !overview.summary.fonts.isEmpty {
        countSection(ShellL10n.string("Fonts"), rows: fontRows(overview))
      }
      mediaSection(overview)
      sheetSection(overview)
    }
  }

  private func countSection<Rows: View>(_ title: String, rows: Rows) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      rows
    }
  }

  private func colorRows(_ overview: ShaarDevToolsCSSOverviewModel) -> some View {
    ForEach(Array(overview.summary.colors.enumerated()), id: \.element.id) { index, item in
      ShaarDevToolsCSSCountRow(
        label: item.label,
        count: item.count,
        paint: ShaarDevToolsCSSOverview.paint(item.label),
        selected: overview.pick == .color(item.label),
        identifier: "shaar.devtools.css.color.\(index)"
      ) {
        model.cssOverview.choose(.color(item.label))
      }
    }
  }

  private func fontRows(_ overview: ShaarDevToolsCSSOverviewModel) -> some View {
    ForEach(Array(overview.summary.fonts.enumerated()), id: \.element.id) { index, item in
      ShaarDevToolsCSSCountRow(
        label: item.label,
        count: item.count,
        paint: nil,
        selected: overview.pick == .font(item.label),
        identifier: "shaar.devtools.css.font.\(index)"
      ) {
        model.cssOverview.choose(.font(item.label))
      }
    }
  }

  @ViewBuilder private func mediaSection(_ overview: ShaarDevToolsCSSOverviewModel) -> some View {
    if !overview.summary.media.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(ShellL10n.string("Media queries"))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        ForEach(overview.summary.media) { item in
          Text(verbatim: item.label)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
      }
    }
  }

  @ViewBuilder private func sheetSection(_ overview: ShaarDevToolsCSSOverviewModel) -> some View {
    let sheets = filteredSheets(overview)
    if !sheets.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        sheetHeading(overview.pick)
        ForEach(sheets, id: \.self) { sheet in
          Text(verbatim: sheet)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
      }
      .accessibilityIdentifier("shaar.devtools.css.sheets")
    }
  }

  private func filteredSheets(_ overview: ShaarDevToolsCSSOverviewModel) -> [String] {
    if let pick = overview.pick { return overview.summary.sheets(matching: pick) }
    return overview.summary.contributingSheets
  }

  @ViewBuilder private func sheetHeading(_ pick: ShaarDevToolsCSSPick?) -> some View {
    switch pick {
    case .color:
      Text(ShellL10n.string("Sheets with this color"))
    case .font:
      Text(ShellL10n.string("Sheets with this font"))
    case nil:
      Text(ShellL10n.string("Sheets"))
    }
  }
}

private struct ShaarDevToolsCSSCountRow: View {
  let label: String
  let count: Int
  let paint: ShaarDevToolsCSSPaint?
  let selected: Bool
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        swatch
        Text(verbatim: label)
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(
          ShellL10n.format("%1$@ declarations", arguments: [.string(String(count))])
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(selected ? Color.primary.opacity(0.08) : Color.clear)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }

  @ViewBuilder private var swatch: some View {
    if let paint {
      Circle()
        .fill(Color(red: paint.red, green: paint.green, blue: paint.blue).opacity(paint.alpha))
        .overlay(Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1))
        .frame(width: 12, height: 12)
    }
  }
}
