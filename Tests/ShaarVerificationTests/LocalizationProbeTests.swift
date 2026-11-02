// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ShaarVerification

@Suite struct LocalizationProbeTests {
  private func evidence(_ language: BrowserLanguage) -> [String: Any] {
    [
      "language": language.localeIdentifier,
      "languages": [language.localeIdentifier, "fr"],
      "htmlLanguage": language.localeIdentifier,
      "htmlDirection": language.isRightToLeft ? "rtl" : "ltr",
    ]
  }

  @Test(arguments: BrowserLanguage.allCases)
  func acceptsMatchingNavigatorAndDocument(language: BrowserLanguage) throws {
    let checks = try LocalizationProbe.validate(evidence(language), language: language)
    #expect(checks.count == 2)
    #expect(checks[0].contains(language.localeIdentifier))
    #expect(checks[1].contains(language.isRightToLeft ? "rtl" : "ltr"))
  }

  @Test func rejectsMalformedAndIncompleteEvidence() {
    #expect(throws: LocalizationProbeError.self) {
      try LocalizationProbe.validate([], language: .hebrew)
    }
    for key in ["language", "languages", "htmlLanguage", "htmlDirection"] {
      var value = evidence(.hebrew)
      value.removeValue(forKey: key)
      #expect(throws: LocalizationProbeError.self) {
        try LocalizationProbe.validate(value, language: .hebrew)
      }
      value[key] = 17
      #expect(throws: LocalizationProbeError.self) {
        try LocalizationProbe.validate(value, language: .hebrew)
      }
    }
  }

  @Test func rejectsWrongPrimaryLanguageAndDocumentDirection() {
    for (key, value): (String, Any) in [
      ("language", "en"), ("languages", ["en", "he"]), ("languages", [String]()),
      ("htmlLanguage", "en"), ("htmlDirection", "ltr"),
    ] {
      var payload = evidence(.hebrew)
      payload[key] = value
      #expect(throws: LocalizationProbeError.self) {
        try LocalizationProbe.validate(payload, language: .hebrew)
      }
    }
  }

  @Test func internalUIWaitsForNavigationAndPopulatedMetadata() throws {
    #expect(throws: LocalizationProbeError.self) {
      try LocalizationProbe.validateInternalUI("invalid", language: .hebrew)
    }
    for payload: [String: Any] in [
      [:], ["url": "about:blank"], ["url": "https://example.invalid/"],
      ["url": "chrome://version/"],
      ["url": "chrome://version/", "language": "", "direction": ""],
    ] {
      #expect(try LocalizationProbe.validateInternalUI(payload, language: .hebrew) == nil)
    }
  }

  @Test(arguments: BrowserLanguage.allCases)
  func internalUIAcceptsRegionalLanguageAndOptionalMetadata(language: BrowserLanguage) throws {
    let direction = language.isRightToLeft ? "rtl" : "ltr"
    for metadata in [
      ["language": "\(language.localeIdentifier)-\(language.isRightToLeft ? "IL" : "US")"],
      ["direction": direction],
      ["language": language.localeIdentifier, "direction": direction],
    ] {
      var payload = metadata
      payload["url"] = "chrome://version/"
      let result = try LocalizationProbe.validateInternalUI(payload, language: language)
      #expect(result?.contains("chrome://version/") == true)
    }
  }

  @Test func internalUIRejectsWrongLanguageOrDirection() {
    for metadata in [
      ["language": "en-US", "direction": "rtl"],
      ["language": "he", "direction": "ltr"],
      ["language": "en"], ["direction": "ltr"],
    ] {
      var payload = metadata
      payload["url"] = "chrome://version/"
      #expect(throws: LocalizationProbeError.self) {
        try LocalizationProbe.validateInternalUI(payload, language: .hebrew)
      }
    }
  }

  @Test func failuresExplainObservedContractMismatch() {
    #expect(
      LocalizationProbeError.malformedEvidence.errorDescription
        == "Localization evidence payload is malformed.")
    #expect(
      LocalizationProbeError.navigatorLanguage(expected: "he", actual: "en").errorDescription
        == "Expected navigator language he, received en.")
    #expect(
      LocalizationProbeError.documentLanguage(expected: "he", direction: "rtl").errorDescription
        == "Expected document lang/dir he/rtl.")
  }
}
