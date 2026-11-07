// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum InspectorAccessibleName {
  /// Localization key for the winning accessible-name source.
  /// Nil when the name is missing or the source is not one of the explained kinds.
  static func source(of name: [String: Any]?) -> String? {
    guard let name else { return nil }
    guard let text = string(name["value"]) else { return nil }
    guard !trimmed(text).isEmpty else { return nil }
    guard let chosen = activeSource(name) else { return nil }
    return phrase(for: chosen)
  }

  /// Chromium lists every candidate. Empty aria-labelledby and aria-label entries stay
  /// in front and are not marked superseded; only an entry with text contributed the name.
  private static func activeSource(_ name: [String: Any]) -> [String: Any]? {
    let sources = name["sources"] as? [[String: Any]] ?? []
    return sources.first { source in
      !ignored(source) && contributedText(source) != nil
    }
  }

  private static func ignored(_ source: [String: Any]) -> Bool {
    if source["superseded"] as? Bool == true { return true }
    if source["invalid"] as? Bool == true { return true }
    return false
  }

  private static func contributedText(_ source: [String: Any]) -> String? {
    guard let text = string(source["value"]) else { return nil }
    let value = trimmed(text)
    if value.isEmpty { return nil }
    return value
  }

  private static func string(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    guard let object = value as? [String: Any] else { return nil }
    return object["value"] as? String
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func phrase(for source: [String: Any]) -> String? {
    if let native = source["nativeSource"] as? String, labelSources.contains(native) {
      return "From a label"
    }
    if source["type"] as? String == "contents" {
      return "From the element's text"
    }
    switch source["attribute"] as? String {
    case "aria-label":
      return "From aria-label"
    case "aria-labelledby":
      return "From aria-labelledby"
    default:
      return nil
    }
  }

  private static let labelSources: Set<String> = [
    "label", "labelfor", "labelwrapped", "legend",
  ]
}
