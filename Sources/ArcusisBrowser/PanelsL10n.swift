// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

enum PanelsL10n {
  static func formattingLocale(
    for language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage,
    systemLocale: Locale = .autoupdatingCurrent
  )
    -> Locale
  {
    if language.isRightToLeft { return Locale(identifier: language.localeIdentifier) }
    guard let region = systemLocale.region?.identifier else {
      return Locale(identifier: language.localeIdentifier)
    }
    return Locale(identifier: "\(language.localeIdentifier)_\(region)")
  }

  static func byteCount(
    _ value: Int64, language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage,
    systemLocale: Locale = .autoupdatingCurrent
  ) -> String {
    value.formatted(
      .byteCount(style: .file).locale(
        formattingLocale(for: language, systemLocale: systemLocale)))
  }

  static func string(_ key: String) -> String {
    string(key, language: BrowserLanguage.currentLaunchLanguage)
  }

  static func string(_ key: String, language: BrowserLanguage) -> String {
    BrowserLocalization.string(
      key, table: "Panels", language: language)
  }

  static func format(_ key: String, _ arguments: BrowserFormatArgument...) -> String {
    BrowserLocalization.format(
      key, table: "Panels", language: BrowserLanguage.currentLaunchLanguage, arguments: arguments)
  }

  static func plural(_ key: String, count: Int) -> String {
    BrowserLocalization.plural(
      key, count: count, table: "Panels", language: BrowserLanguage.currentLaunchLanguage)
  }
}
