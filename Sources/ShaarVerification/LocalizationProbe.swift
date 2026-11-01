// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

enum LocalizationProbe {
  @MainActor static func run(arguments: [String]) -> Int32 {
    EngineProbe.runLocalization(arguments: arguments)
  }

  static let script = """
    ({language:navigator.language,languages:Array.from(navigator.languages),
      htmlLanguage:document.documentElement.lang,htmlDirection:document.documentElement.dir})
    """
  static let internalUIScript = """
    ({url:location.href,language:document.documentElement.lang,direction:document.documentElement.dir})
    """

  static func validate(_ value: Any, language: BrowserLanguage) throws -> [String] {
    guard let evidence = value as? [String: Any],
      let actual = evidence["language"] as? String,
      let languages = evidence["languages"] as? [String],
      let htmlLanguage = evidence["htmlLanguage"] as? String,
      let htmlDirection = evidence["htmlDirection"] as? String
    else { throw LocalizationProbeError.malformedEvidence }

    let expected = language.localeIdentifier
    let expectedDirection = language.isRightToLeft ? "rtl" : "ltr"
    guard actual == expected, languages.first == expected else {
      throw LocalizationProbeError.navigatorLanguage(expected: expected, actual: actual)
    }
    guard htmlLanguage == expected, htmlDirection == expectedDirection else {
      throw LocalizationProbeError.documentLanguage(
        expected: expected, direction: expectedDirection)
    }
    return [
      "navigator.language and navigator.languages begin with \(expected)",
      "fixture document lang and dir are \(expected)/\(expectedDirection)",
    ]
  }

  static func validateInternalUI(_ value: Any, language: BrowserLanguage) throws -> String? {
    guard let evidence = value as? [String: Any] else {
      throw LocalizationProbeError.malformedEvidence
    }
    guard let url = evidence["url"] as? String, url.hasPrefix("chrome://version") else {
      return nil
    }
    let htmlLanguage = evidence["language"] as? String ?? ""
    let direction = evidence["direction"] as? String ?? ""
    guard !htmlLanguage.isEmpty || !direction.isEmpty else { return nil }
    let expected = language.localeIdentifier
    let expectedDirection = language.isRightToLeft ? "rtl" : "ltr"
    let actualLanguage =
      htmlLanguage.isEmpty
      ? nil : Locale(identifier: htmlLanguage).language.languageCode?.identifier.lowercased()
    guard htmlLanguage.isEmpty || actualLanguage == expected,
      direction.isEmpty || direction == expectedDirection
    else {
      throw LocalizationProbeError.documentLanguage(
        expected: expected, direction: expectedDirection)
    }
    return "chrome://version UI observed url=\(url), lang=\(htmlLanguage), dir=\(direction)"
  }
}

enum LocalizationProbeError: LocalizedError {
  case malformedEvidence
  case navigatorLanguage(expected: String, actual: String)
  case documentLanguage(expected: String, direction: String)

  var errorDescription: String? {
    switch self {
    case .malformedEvidence: "Localization evidence payload is malformed."
    case .navigatorLanguage(let expected, let actual):
      "Expected navigator language \(expected), received \(actual)."
    case .documentLanguage(let expected, let direction):
      "Expected document lang/dir \(expected)/\(direction)."
    }
  }
}
