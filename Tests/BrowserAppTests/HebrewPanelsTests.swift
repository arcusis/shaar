// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct HebrewPanelsTests {
  @Test func selectedLanguagesKeepLocalizedFormattingAndEnglishRegionalDefaults() {
    #expect(PanelsL10n.formattingLocale(for: .hebrew).identifier == "he")
    let english = PanelsL10n.formattingLocale(for: .english)
    #expect(english.language.languageCode?.identifier == "en")
    #expect(english.region == Locale.autoupdatingCurrent.region)
  }

  @Test func englishPanelValuesDoNotUseMacOSHebrewLanguage() {
    let macLocale = Locale(identifier: "he_IL")
    let english = PanelsL10n.formattingLocale(for: .english, systemLocale: macLocale)
    #expect(english.language.languageCode?.identifier == "en")
    #expect(english.region?.identifier == "IL")
    let bytes = PanelsL10n.byteCount(1, language: .english, systemLocale: macLocale)
    #expect(bytes == "1 byte")
    let date = Date(timeIntervalSince1970: 1_768_435_200)
    let dateLabel = date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .omitted).locale(english))
    #expect(dateLabel.contains("Jan"))
  }

  @Test func panelCatalogContainsHebrewPinHelpAndNaturalTerms() {
    #expect(
      BrowserLocalization.string("Pin to toolbar", table: "Panels", language: .hebrew)
        == "הצמדה לסרגל הכלים")
    #expect(
      BrowserLocalization.string("Unpin from toolbar", table: "Panels", language: .hebrew)
        == "ביטול ההצמדה לסרגל הכלים")
    #expect(
      BrowserLocalization.string("Space", table: "Panels", language: .hebrew) == "מרחב")
    #expect(
      BrowserLocalization.string("Not asked yet", table: "Panels", language: .hebrew)
        == "טרם התבקשה הרשאה")
    #expect(
      BrowserLocalization.string(
        "Browser engine did not provide a complete site access list. Extension may access sites not listed above.",
        table: "Panels", language: .hebrew
      )
      .contains("רשימה מלאה של האתרים שהתוסף יכול לגשת אליהם"))
  }

  @Test func importPreviewSourceAndItemTypesHaveHebrewLabels() {
    #expect(
      BrowserLocalization.format(
        "From %@", table: "Panels", language: .hebrew, arguments: [.string("Chrome")])
        == "מ־\u{2068}Chrome\u{2069}")
    #expect(
      BrowserLocalization.string("Bookmark", table: "Panels", language: .hebrew) == "סימנייה")
    #expect(
      BrowserLocalization.string("History", table: "Panels", language: .hebrew) == "היסטוריה")
  }

  @Test func pipCornerChromeMirrorsWhileTransportStaysCentered() {
    let ltr = PictureInPictureControlsView.cornerFrames(width: 356, rightToLeft: false)
    let rtl = PictureInPictureControlsView.cornerFrames(width: 356, rightToLeft: true)
    #expect(ltr.backToTab == 8)
    #expect(ltr.minimize < ltr.close)
    #expect(rtl.backToTab > rtl.close)
    #expect(rtl.close < rtl.minimize)
    #expect(rtl.backToTab == ltr.close)
    #expect(abs(rtl.close - (356 - ltr.close - 28)) < 0.001)
    #expect(abs(rtl.minimize - (356 - ltr.minimize - 28)) < 0.001)
  }

  @Test func byteCountUsesHebrewFormatStyleAndEnglishRegionalFormatter() {
    let value: Int64 = 1_048_576
    #expect(
      PanelsL10n.byteCount(value, language: .hebrew)
        == value.formatted(.byteCount(style: .file).locale(Locale(identifier: "he"))))
  }

  @Test func browserLanguageResolverSelectsHebrewForRightToLeftPanels() {
    #expect(
      BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["he-IL"]) == .hebrew)
    #expect(
      BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["iw"]) == .hebrew)
    #expect(BrowserLanguage.hebrew.isRightToLeft)
  }
}
