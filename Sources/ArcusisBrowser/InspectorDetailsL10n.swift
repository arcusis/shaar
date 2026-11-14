// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum InspectorDetailsL10n {
  static func string(_ key: String) -> String {
    BrowserLocalization.string(
      key, table: "InspectorDetails", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func format(_ key: String, arguments: [BrowserFormatArgument]) -> String {
    BrowserLocalization.format(
      key, table: "InspectorDetails", language: BrowserLanguage.currentLaunchLanguage,
      arguments: arguments)
  }

  static func plural(_ key: String, count: Int) -> String {
    BrowserLocalization.plural(
      key, count: count, table: "InspectorDetails", language: BrowserLanguage.currentLaunchLanguage)
  }

  /// Translate only Inspector-authored failures; preserve renderer-provided error text.
  static func display(
    _ value: String, language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage
  ) -> String {
    switch value {
    case "Accessibility data exceeds supported limits.",
      "Asset data exceeds supported limits.", "Asset data is unavailable or exceeds 32 MiB.",
      "Chromium did not return this resource's content.", "Component data does not belong to this tree.",
      "Component tree exceeds supported limits.", "Component values exceed supported limits.",
      "Element details exceed the supported size.", "The selected element is no longer available.",
      "This asset is no longer selected.":
      return BrowserLocalization.string(value, table: "InspectorDetails", language: language)
    case "Chromium could not capture this element.", "The page could not complete the Inspector request.",
      "This Inspector target is no longer available.":
      return BrowserLocalization.string(value, table: "Inspector", language: language)
    default:
      return value
    }
  }

  static func text(_ key: String) -> Text { Text(string(key)) }

  static func ltr(_ value: String) -> String { "\u{2066}\(value)\u{2069}" }

}
