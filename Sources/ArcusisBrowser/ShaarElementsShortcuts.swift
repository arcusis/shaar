// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI

enum ShaarElementsModifier: Hashable {
  case command
  case shift
  case option
  case control
}

enum ShaarElementsKey: Equatable {
  case character(Character)
  case `return`
  case up
  case down
  case escape
  case delete
  case f12
}

enum ShaarElementsShortcutContext: Equatable {
  case tree
  case searchField
  case lengthField
}

enum ShaarElementsShortcut: Equatable {
  case focusSearch
  case toggleVisibility
  case editAsHTML
  case nudgeLength(Decimal)
}

struct ShaarElementsKeyPress: Equatable {
  var key: ShaarElementsKey
  var modifiers: Set<ShaarElementsModifier>

  init(key: ShaarElementsKey, modifiers: Set<ShaarElementsModifier> = []) {
    self.key = key
    self.modifiers = modifiers
  }
}

extension ShaarElementsKeyPress {
  init(_ press: KeyPress) {
    var flags: Set<ShaarElementsModifier> = []
    if press.modifiers.contains(.command) { flags.insert(.command) }
    if press.modifiers.contains(.shift) { flags.insert(.shift) }
    if press.modifiers.contains(.option) { flags.insert(.option) }
    if press.modifiers.contains(.control) { flags.insert(.control) }
    modifiers = flags
    if press.key == .return {
      key = .return
    } else if press.key == .upArrow {
      key = .up
    } else if press.key == .downArrow {
      key = .down
    } else if press.key == .escape {
      key = .escape
    } else if press.key == .delete {
      key = .delete
    } else {
      key = .character(press.key.character)
    }
  }
}

enum ShaarElementsShortcuts {
  static func action(
    for press: ShaarElementsKeyPress, context: ShaarElementsShortcutContext
  ) -> ShaarElementsShortcut? {
    switch press.key {
    case .character(let character):
      return characterAction(character, modifiers: press.modifiers, context: context)
    case .return:
      guard context == .tree, press.modifiers.isEmpty else { return nil }
      return .editAsHTML
    case .up, .down:
      return nudge(press, context: context)
    case .escape, .delete, .f12:
      return nil
    }
  }

  private static func characterAction(
    _ character: Character, modifiers: Set<ShaarElementsModifier>,
    context: ShaarElementsShortcutContext
  ) -> ShaarElementsShortcut? {
    if character == "f" || character == "F" {
      guard modifiers == [.command] else { return nil }
      return .focusSearch
    }
    if character == "h" || character == "H" {
      guard context == .tree else { return nil }
      guard !modifiers.contains(.command), !modifiers.contains(.option),
        !modifiers.contains(.control)
      else { return nil }
      return .toggleVisibility
    }
    return nil
  }

  private static func nudge(
    _ press: ShaarElementsKeyPress, context: ShaarElementsShortcutContext
  ) -> ShaarElementsShortcut? {
    guard context == .lengthField else { return nil }
    guard !press.modifiers.contains(.command), !press.modifiers.contains(.control) else {
      return nil
    }
    let magnitude = step(press.modifiers)
    let signed: Decimal = press.key == .down ? -magnitude : magnitude
    return .nudgeLength(signed)
  }

  private static func step(_ modifiers: Set<ShaarElementsModifier>) -> Decimal {
    if modifiers.contains(.option) { return Decimal(string: "0.1", locale: posix) ?? 0 }
    if modifiers.contains(.shift) { return 10 }
    return 1
  }

  private static let posix = Locale(identifier: "en_US_POSIX")
}

enum ShaarElementVisibility {
  static func isHidden(_ style: String) -> Bool {
    visibilityValue(in: style) == "hidden"
  }

  static func toggledStyle(_ style: String) -> String {
    let kept = declarations(style).filter { propertyName($0) != "visibility" }
    if isHidden(style) { return join(kept) }
    return join(kept + ["visibility: hidden"])
  }

  private static func visibilityValue(in style: String) -> String {
    guard let last = declarations(style).last(where: { propertyName($0) == "visibility" }) else {
      return ""
    }
    return propertyValue(last)
  }

  private static func declarations(_ style: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    for character in style {
      if quote != nil {
        current.append(character)
        if character == quote { quote = nil }
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        current.append(character)
        continue
      }
      if character == ";" {
        append(current, to: &parts)
        current = ""
        continue
      }
      current.append(character)
    }
    append(current, to: &parts)
    return parts
  }

  private static func append(_ raw: String, to parts: inout [String]) {
    let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !piece.isEmpty { parts.append(piece) }
  }

  private static func join(_ parts: [String]) -> String {
    parts.joined(separator: "; ")
  }

  private static func propertyName(_ declaration: String) -> String {
    guard let colon = declaration.firstIndex(of: ":") else { return "" }
    return declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func propertyValue(_ declaration: String) -> String {
    guard let colon = declaration.firstIndex(of: ":") else { return "" }
    let raw = declaration[declaration.index(after: colon)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripImportant(String(raw)).lowercased()
  }

  private static func stripImportant(_ value: String) -> String {
    var text = value
    let flags: String.CompareOptions = [.regularExpression, .caseInsensitive]
    if let range = text.range(of: #"\s*!important\s*$"#, options: flags) {
      text.removeSubrange(range)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum ShaarCSSLength {
  struct Edit: Equatable {
    let range: NSRange
    let replacement: String
  }

  static func isLengthFieldLabel(_ label: String) -> Bool {
    label == InspectorL10n.string("CSS value")
  }

  static func nudged(_ text: String, caret: Int, by delta: Decimal) -> String? {
    guard let edit = edit(text, caret: caret, by: delta) else { return nil }
    return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  }

  static func edit(_ text: String, caret: Int, by delta: Decimal) -> Edit? {
    let storage = text as NSString
    guard let token = token(in: storage, caret: caret) else { return nil }
    let original = storage.substring(with: token.number)
    let replacement = adding(original, delta: delta)
    guard replacement != original else { return nil }
    return Edit(range: token.number, replacement: replacement)
  }

  private struct Token {
    let number: NSRange
    let span: NSRange
    let unit: String
  }

  private static func token(in text: NSString, caret: Int) -> Token? {
    let found = tokens(in: text)
    guard !found.isEmpty else { return nil }
    let clamped = min(max(caret, 0), text.length)
    let chosen: Token
    if let inside = found.last(where: { contains(clamped, span: $0.span) }) {
      chosen = inside
    } else if clamped <= found[0].span.location {
      chosen = found[0]
    } else {
      chosen = found.last(where: { $0.span.location + $0.span.length <= clamped }) ?? found[0]
    }
    guard unitAllowed(chosen.unit) else { return nil }
    return chosen
  }

  private static func contains(_ caret: Int, span: NSRange) -> Bool {
    caret >= span.location && caret <= span.location + span.length
  }

  private static func tokens(in text: NSString) -> [Token] {
    guard let expression = try? NSRegularExpression(pattern: numberPattern) else { return [] }
    let full = NSRange(location: 0, length: text.length)
    return expression.matches(in: text as String, range: full).compactMap { match in
      guard match.numberOfRanges >= 3 else { return nil }
      let number = match.range(at: 1)
      let unitRange = match.range(at: 2)
      let unit = unitRange.location == NSNotFound ? "" : text.substring(with: unitRange)
      let span = NSRange(
        location: number.location,
        length: number.length + (unitRange.length > 0 ? unitRange.length : 0))
      return Token(number: number, span: span, unit: unit)
    }
  }

  private static func unitAllowed(_ unit: String) -> Bool {
    unit.isEmpty || units.contains(unit.lowercased())
  }

  private static func adding(_ original: String, delta: Decimal) -> String {
    guard var value = Decimal(string: original, locale: posix) else { return original }
    value += delta
    let scale = max(fractionDigits(original), fractionDigits(delta))
    var source = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, scale, .plain)
    return plain(rounded)
  }

  private static func fractionDigits(_ text: String) -> Int {
    guard let dot = text.firstIndex(of: ".") else { return 0 }
    return text.distance(from: text.index(after: dot), to: text.endIndex)
  }

  private static func fractionDigits(_ value: Decimal) -> Int {
    max(0, -value.exponent)
  }

  private static func plain(_ value: Decimal) -> String {
    if value == 0 { return "0" }
    let formatter = NumberFormatter()
    formatter.locale = posix
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 8
    formatter.decimalSeparator = "."
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
  }

  private static let posix = Locale(identifier: "en_US_POSIX")
  private static let numberPattern = #"(?<![#\w.])(-?(?:\d+\.\d+|\.\d+|\d+))([a-zA-Z%]*)"#
  private static let units: Set<String> = [
    "%", "px", "em", "rem", "ch", "ex", "lh", "rlh", "vh", "vw", "vmin", "vmax",
    "svh", "lvh", "dvh", "svw", "lvw", "dvw", "vi", "vb", "fr",
    "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax",
    "pt", "pc", "in", "cm", "mm", "q",
  ]
}
