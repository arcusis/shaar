// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum InspectorL10n {
  static func forwardChevron(isRightToLeft: Bool) -> String {
    isRightToLeft ? "chevron.left" : "chevron.right"
  }

  static func string(_ key: String) -> String {
    BrowserLocalization.string(
      key, table: "Inspector", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func format(_ key: String, arguments: [BrowserFormatArgument]) -> String {
    BrowserLocalization.format(
      key, table: "Inspector", language: BrowserLanguage.currentLaunchLanguage,
      arguments: arguments)
  }

  static func plural(_ key: String, count: Int) -> String {
    BrowserLocalization.plural(
      key, count: count, table: "Inspector", language: BrowserLanguage.currentLaunchLanguage)
  }

  static func text(_ key: String) -> Text { Text(string(key)) }

  /// Translate only known Inspector-authored descriptors; leave renderer and page values intact.
  static func display(_ value: String) -> String {
    switch value {
    case "A solid background could not be resolved.", "Inline overrides", "Browser default",
      "Source unavailable",
      "Text", "Background", "Border", "Border top", "Border right", "Border bottom",
      "Border left",
      "Image or gradient behind text",
      "Opacity, filter, or blending requires pixel sampling",
      "Wide-gamut colors shown as sRGB approximations",
      "This page is no longer available.", "Element data exceeds the supported size.",
      "Element data could not be displayed.", "Chromium did not return rendered font data.",
      "Computed styles are unavailable.", "Style data exceeds the supported size.",
      "CSS could not be applied.", "CSS could not be restored.",
      "Lock an element before editing.", "Invalid CSS declaration.",
      "This rule cannot be edited from the page.", "Invalid selector.",
      "Chromium does not support this CSS value.", "No edits to undo.",
      "Page styles changed after this edit. Undo would overwrite them.",
      "An element capture is already in progress.", "Lock an element first.",
      "Select an element smaller than 16 megapixels at 2×.",
      "Chromium could not capture this element.",
      "The page could not complete the Inspector request.",
      "This Inspector target is no longer available.":
      return string(value)
    default:
      return value
    }
  }
}

extension View {
  func inspectorLocalization() -> some View {
    let language = BrowserLanguage.currentLaunchLanguage
    return environment(\.locale, Locale(identifier: language.localeIdentifier))
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
  }
}
