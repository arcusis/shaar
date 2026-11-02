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

  static func text(_ key: String) -> Text { Text(string(key)) }

  static func ltr(_ value: String) -> String { "\u{2066}\(value)\u{2069}" }

}
