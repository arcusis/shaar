// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum InspectorBoxEdit {
  struct Change: Equatable {
    let property: String
    let value: String
  }

  static func property(region: String, index: Int) -> String? {
    if region == "content" {
      if index == 0 { return "width" }
      if index == 1 { return "height" }
      return nil
    }
    guard (0..<4).contains(index) else { return nil }
    let side = ["top", "right", "bottom", "left"][index]
    if region == "margin" { return "margin-" + side }
    if region == "padding" { return "padding-" + side }
    if region == "border" { return "border-" + side + "-width" }
    return nil
  }

  /// A bare number becomes pixels. An empty field clears the override. Other text is kept.
  static func cssValue(_ typed: String) -> String {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if Double(trimmed) != nil { return trimmed + "px" }
    return trimmed
  }

  static func editableText(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasSuffix("px") else { return trimmed }
    let stem = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Double(stem) != nil else { return trimmed }
    return stem
  }

  static func draft(_ raw: String) -> String {
    let text = editableText(raw)
    if Double(text) == 0 { return "0" }
    return text
  }

  static func draft(for box: InspectorSelection.Box, edge: String?) -> String {
    guard let edge, let raw = raw(for: box, edge: edge) else { return "" }
    return draft(raw)
  }

  /// Nil means the typed value matches the diagram, so the edit must not push undo history.
  static func submission(region: String, index: Int, typed: String, box: InspectorSelection.Box)
    -> Change?
  {
    guard let property = property(region: region, index: index),
      let current = raw(box, region: region, index: index)
    else { return nil }
    let next = cssValue(typed)
    if next == cssValue(editableText(current)) { return nil }
    return Change(property: property, value: next)
  }

  static func submission(edge: String, typed: String, box: InspectorSelection.Box) -> Change? {
    guard let parts = parts(edge) else { return nil }
    return submission(region: parts.region, index: parts.index, typed: typed, box: box)
  }

  private static func raw(for box: InspectorSelection.Box, edge: String) -> String? {
    guard let parts = parts(edge) else { return nil }
    return raw(box, region: parts.region, index: parts.index)
  }

  private static func raw(_ box: InspectorSelection.Box, region: String, index: Int) -> String? {
    if region == "content" {
      if index == 0 { return InspectorColor.number(box.contentWidth.rounded()) }
      if index == 1 { return InspectorColor.number(box.contentHeight.rounded()) }
      return nil
    }
    let values = values(box, region: region)
    guard values.indices.contains(index) else { return nil }
    return values[index]
  }

  private static func values(_ box: InspectorSelection.Box, region: String) -> [String] {
    if region == "margin" { return box.margin }
    if region == "padding" { return box.padding }
    if region == "border" { return box.border }
    return []
  }

  private static func parts(_ edge: String) -> (region: String, index: Int)? {
    guard let last = edge.last, let index = Int(String(last)), edge.count > 1 else { return nil }
    return (String(edge.dropLast()), index)
  }
}
