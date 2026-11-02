// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI

enum SettingsL10n {
  static func string(_ key: String) -> String {
    BrowserLocalization.string(key, table: "Settings")
  }

  static func format(_ key: String, _ arguments: BrowserFormatArgument...) -> String {
    BrowserLocalization.format(key, table: "Settings", arguments: arguments)
  }

  static func notice(_ message: String) -> String {
    let saveFailure = "Window changes could not be saved. "
    if message.hasPrefix(saveFailure) {
      return format(
        "Window changes could not be saved. %@",
        .string(String(message.dropFirst(saveFailure.count))))
    }
    return string(message)
  }
}

extension View {
  func settingsLocalization() -> some View {
    let language = BrowserLanguage.currentLaunchLanguage
    return environment(\.locale, Locale(identifier: language.localeIdentifier))
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
  }
}
