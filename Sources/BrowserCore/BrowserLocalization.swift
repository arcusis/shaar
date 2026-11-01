// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Typed arguments prevent accidental placeholder type and order drift at call sites.
public enum BrowserFormatArgument: Sendable {
  case string(String)
  case integer(Int)
  case decimal(Double)
}

/// Package-owned catalog lookup. Missing translations always fall back to English, then key.
public enum BrowserLocalization {
  public static let resourceBundleURL = Bundle.module.bundleURL

  private static let bundle = Bundle.module

  private static func localizedBundle(_ language: BrowserLanguage) -> Bundle {
    guard let url = bundle.url(forResource: language.localeIdentifier, withExtension: "lproj"),
      let localized = Bundle(url: url)
    else { return bundle }
    return localized
  }

  public static func string(
    _ key: String,
    table: String = "Core",
    language: BrowserLanguage? = nil
  ) -> String {
    let selected = (language ?? .currentLaunchLanguage).resolved
    let localized = localizedBundle(selected).localizedString(forKey: key, value: key, table: table)
    guard localized == key, selected != .english else { return localized }
    return localizedBundle(.english).localizedString(forKey: key, value: key, table: table)
  }

  public static func format(
    _ key: String,
    table: String = "Core",
    language: BrowserLanguage? = nil,
    arguments: [BrowserFormatArgument]
  ) -> String {
    let selected = (language ?? .currentLaunchLanguage).resolved
    let template = string(key, table: table, language: selected)
    let values: [CVarArg] = arguments.map {
      switch $0 {
      case .string(let value): value as NSString
      case .integer(let value): value
      case .decimal(let value): value
      }
    }
    return String(
      format: template, locale: Locale(identifier: selected.localeIdentifier), arguments: values)
  }

  /// Format through native String Catalog plural variations with explicit selected locale.
  public static func plural(
    _ key: String,
    count: Int,
    table: String = "Core",
    language: BrowserLanguage? = nil,
    arguments: [BrowserFormatArgument] = []
  ) -> String {
    format(
      key, table: table, language: language,
      arguments: [.integer(count)] + arguments)
  }

}
