// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum InspectorToolsL10n {
  static func string(_ key: String) -> String {
    BrowserLocalization.string(
      key, table: "InspectorTools", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func format(_ key: String, arguments: [BrowserFormatArgument]) -> String {
    BrowserLocalization.format(
      key, table: "InspectorTools", language: BrowserLanguage.currentLaunchLanguage,
      arguments: arguments)
  }

  static func plural(_ key: String, count: Int) -> String {
    BrowserLocalization.plural(
      key, count: count, table: "InspectorTools", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func text(_ key: String) -> Text { Text(string(key)) }

  /// Translate known Inspector Tools errors while preserving unknown page-provided details.
  static func backendError(
    _ message: String, language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage
  ) -> String {
    switch message {
    case "Storage is not available in this document.",
      "Value exceeds the 256K-character editor limit.",
      "Storage could not be read.",
      "Storage key or value exceeds the editor limit.",
      "Storage could not be changed; it may be restricted or full.",
      "Chromium rejected this cookie.":
      BrowserLocalization.string(message, table: "InspectorTools", language: language)
    default:
      message
    }
  }
}
