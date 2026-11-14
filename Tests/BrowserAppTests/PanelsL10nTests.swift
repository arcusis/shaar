// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest

@testable import ArcusisBrowser

final class PanelsL10nTests: XCTestCase {
  func testFormattingLocaleUsesTheSystemRegionForLeftToRightLanguage() {
    let locale = PanelsL10n.formattingLocale(
      for: .english, systemLocale: Locale(identifier: "en_GB"))

    XCTAssertEqual(locale.identifier, "en_GB")
  }

  func testEnglishFormattingRetainsHebrewSystemRegionWithoutUsingHebrewLanguage() {
    let locale = PanelsL10n.formattingLocale(
      for: .english, systemLocale: Locale(identifier: "he_IL"))

    XCTAssertEqual(locale.identifier, "en_IL")
  }

  func testByteCountUsesSelectedLanguageWithTheSystemRegion() {
    let systemLocale = Locale(identifier: "he_IL")
    let expected = Int64(1_000_000).formatted(
      .byteCount(style: .file).locale(Locale(identifier: "en_IL")))

    XCTAssertEqual(
      PanelsL10n.byteCount(1_000_000, language: .english, systemLocale: systemLocale), expected)
  }

  func testRightToLeftLanguageDoesNotInheritTheSystemRegion() {
    let locale = PanelsL10n.formattingLocale(
      for: .hebrew, systemLocale: Locale(identifier: "en_GB"))

    XCTAssertEqual(locale.identifier, "he")
  }

  func testMissingSystemRegionFallsBackToTheSelectedLanguage() {
    let locale = PanelsL10n.formattingLocale(
      for: .english, systemLocale: Locale(identifier: "en"))

    XCTAssertEqual(locale.identifier, "en")
  }
}
