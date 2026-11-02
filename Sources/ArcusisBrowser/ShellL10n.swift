// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum ShellL10n {
  static func string(_ key: String) -> String {
    BrowserLocalization.string(key, table: "Shell", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func format(_ key: String, arguments: [BrowserFormatArgument]) -> String {
    BrowserLocalization.format(
      key, table: "Shell", language: BrowserLanguage.currentLaunchLanguage, arguments: arguments)
  }

  static func plural(_ key: String, count: Int) -> String {
    BrowserLocalization.plural(
      key, count: count, table: "Shell", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func text(_ key: String) -> Text { Text(string(key)) }
}

extension View {
  func shellLocalization() -> some View {
    let language = BrowserLanguage.currentLaunchLanguage
    return environment(\.locale, Locale(identifier: language.localeIdentifier))
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
  }
}
