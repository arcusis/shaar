// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Launch language choice. Raw values are persisted; keep existing values stable.
public enum BrowserLanguage: String, CaseIterable, Sendable {
  case systemDefault = "systemDefault"
  case english = "en"
  case hebrew = "he"

  public static let selectionDefaultsKey = "BrowserLanguage.selection"
  private static let systemLanguagesKey = "BrowserLanguage.systemAppleLanguages"

  /// Choice persisted for the next launch.
  public static var selection: BrowserLanguage {
    get {
      guard let raw = UserDefaults.standard.string(forKey: selectionDefaultsKey),
        let value = BrowserLanguage(rawValue: raw)
      else { return .systemDefault }
      return value
    }
    set { store(newValue) }
  }

  /// Keep the override in this app's domain so Cocoa sees it before framework startup.
  /// Preserve an existing macOS per-app choice while an explicit Shaar choice owns the override.
  public static func store(
    _ selection: BrowserLanguage, defaults: UserDefaults = .standard,
    domainName: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
  ) {
    let domain = defaults.persistentDomain(forName: domainName) ?? [:]
    if selection == .systemDefault {
      if let previous = domain[systemLanguagesKey] as? [String] {
        let owned = domain[selectionDefaultsKey] as? String
        if domain["AppleLanguages"] as? [String] == owned.map({ [$0] }) {
          if previous.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
          } else {
            defaults.set(previous, forKey: "AppleLanguages")
          }
        }
        defaults.removeObject(forKey: systemLanguagesKey)
      }
    } else {
      if domain[systemLanguagesKey] == nil {
        defaults.set(domain["AppleLanguages"] as? [String] ?? [], forKey: systemLanguagesKey)
      }
      defaults.set([selection.rawValue], forKey: "AppleLanguages")
    }
    defaults.set(selection.rawValue, forKey: selectionDefaultsKey)
  }

  public static let launchSelection = selection

  /// Locale chosen once for this process launch.
  public static let currentLaunchLanguage = resolve(
    selection: launchSelection,
    preferredLanguages: Locale.preferredLanguages)

  /// Pin Cocoa and Chromium to resolved launch language without changing persistent preferences.
  /// Call before loading app/framework bundles or creating AppKit application state.
  public static func applyToCurrentProcess() {
    let language = currentLaunchLanguage.localeIdentifier
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleLanguages"] = [language]
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }

  public static var supported: [BrowserLanguage] { [.english, .hebrew] }

  public var resolved: BrowserLanguage {
    self == .systemDefault
      ? Self.resolve(selection: self, preferredLanguages: Locale.preferredLanguages) : self
  }

  public var localeIdentifier: String {
    switch resolved {
    case .systemDefault, .english: "en"
    case .hebrew: "he"
    }
  }

  public var isRightToLeft: Bool { resolved == .hebrew }

  /// Pure resolver. Hebrew's legacy `iw` locale alias is accepted from macOS preferences.
  public static func resolve(selection: BrowserLanguage, preferredLanguages: [String])
    -> BrowserLanguage
  {
    guard selection == .systemDefault else { return selection }
    for preferred in preferredLanguages {
      let code =
        Locale(identifier: preferred).language.languageCode?.identifier.lowercased()
        ?? preferred.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?
        .lowercased()
      if code == "he" || code == "iw" { return .hebrew }
      if code == "en" { return .english }
    }
    return .english
  }
}
