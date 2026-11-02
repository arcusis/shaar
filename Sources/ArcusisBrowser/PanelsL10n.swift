// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

enum PanelsL10n {
  static func formattingLocale(
    for language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage
  )
    -> Locale
  {
    language.isRightToLeft ? Locale(identifier: language.localeIdentifier) : .autoupdatingCurrent
  }

  static func byteCount(
    _ value: Int64, language: BrowserLanguage = BrowserLanguage.currentLaunchLanguage
  ) -> String {
    if language.isRightToLeft {
      return value.formatted(.byteCount(style: .file).locale(formattingLocale(for: language)))
    }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
  }

  static func string(_ key: String) -> String {
    BrowserLocalization.string(
      key, table: "Panels", language: BrowserLanguage.currentLaunchLanguage)
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
