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

  static func notice(
    _ message: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    let key = "Window changes could not be saved. %@"
    let marker = "__settings_notice_detail_marker__"
    let shellSample = BrowserLocalization.format(
      key, table: "Shell", language: language, arguments: [.string(marker)])
    guard let markerRange = shellSample.range(of: marker) else {
      return BrowserLocalization.string(message, table: "Settings", language: language)
    }
    let prefix = String(shellSample[..<markerRange.lowerBound])
    let suffix = String(shellSample[markerRange.upperBound...])
    guard message.hasPrefix(prefix), message.hasSuffix(suffix),
      message.count >= prefix.count + suffix.count
    else {
      if language.resolved == .hebrew {
        return BrowserLocalization.string(
          "Window changes could not be saved. Try again.", table: "Settings", language: language)
      }
      return BrowserLocalization.string(message, table: "Settings", language: language)
    }
    let detail = String(message.dropFirst(prefix.count).dropLast(suffix.count))
    return BrowserLocalization.format(
      key, table: "Settings", language: language, arguments: [.string(detail)])
  }
}

extension View {
  func settingsLocalization() -> some View {
    let language = BrowserLanguage.currentLaunchLanguage
    return environment(\.locale, Locale(identifier: language.localeIdentifier))
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
  }
}
