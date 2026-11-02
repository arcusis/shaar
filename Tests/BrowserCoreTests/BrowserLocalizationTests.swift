// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func coreCatalogLocalizesProductMeaningAndFreshSessionDefaults() throws {
  #expect(ProductIdentity.name == "Shaar")
  #expect(ProductIdentity.dataFolderName == "Arcusis Browser")
  #expect(
    BrowserLocalization.string("the gateway to the internet", language: .hebrew)
      == "השער לאינטרנט")

  let hebrew = BrowserSession.fresh(language: .hebrew)
  #expect(hebrew.profiles.map(\.name) == ["אישי", "עבודה"])
  #expect(hebrew.spaces.map(\.name) == ["אישי", "עבודה"])
}

@Test func decodingExistingEnglishNamesPreservesPersistedUserData() throws {
  let existing = BrowserSession.fresh(language: .english)
  let data = try JSONEncoder().encode(existing)
  let restored = try JSONDecoder().decode(BrowserSession.self, from: data)

  #expect(BrowserLocalization.string("Personal", language: .hebrew) == "אישי")
  #expect(restored.profiles.map(\.name) == ["Personal", "Work"])
  #expect(restored.spaces.map(\.name) == ["Personal", "Work"])
}

@Test func languageResolverHonorsOverridesAliasesAndUnsupportedPreferences() {
  #expect(
    BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["he-IL", "en-US"])
      == .hebrew)
  #expect(
    BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["iw-IL"]) == .hebrew)
  #expect(
    BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["fr-FR"]) == .english)
  #expect(BrowserLanguage.resolve(selection: .english, preferredLanguages: ["he-IL"]) == .english)
  #expect(BrowserLanguage.resolve(selection: .hebrew, preferredLanguages: ["en-US"]) == .hebrew)
}

@Test func computedCoreTitlesUseExplicitCatalogKeysInBothLanguages() {
  #expect(CommandFilter.allCases.map(\.title) == ["Tabs", "History", "Bookmarks", "Actions"])
  #expect(
    CommandFilter.allCases.map { BrowserLocalization.string($0.title, language: .hebrew) }
      == ["לשוניות", "היסטוריה", "סימניות", "פעולות"])
  #expect(LibrarySection.allCases.map(\.title) == ["Bookmarks", "History"])
  #expect(
    LibrarySection.allCases.map {
      BrowserLocalization.string($0 == .bookmarks ? "Bookmarks" : "History", language: .hebrew)
    } == ["סימניות", "היסטוריה"])
  #expect(
    SplitLayoutPreset.allCases.map(\.title) == [
      "Side by Side", "Stacked", "One Left, Rest Stacked", "One Top, Rest Side by Side", "Grid",
    ])
  #expect(
    SplitLayoutPreset.allCases.map { BrowserLocalization.string($0.title, language: .hebrew) }
      == [
        "זה לצד זה", "זו מעל זו", "אחת מימין, השאר בטור", "אחת למעלה, השאר זו לצד זו", "תצוגת רשת",
      ])
}

@Test func typedFormattingAndUnknownKeysUseSelectedCatalogAndEnglishFallback() {
  let formatted = BrowserLocalization.format(
    "Bookmark · %@ profile · %@", language: .hebrew,
    arguments: [.string("Alex"), .string("Studio")])
  // Foundation may isolate Latin substitutions inside an RTL format string.
  let readable = formatted.replacingOccurrences(of: "\u{2068}", with: "")
    .replacingOccurrences(of: "\u{2069}", with: "")
  #expect(readable == "סימנייה · פרופיל Alex · Studio")
  #expect(
    BrowserLocalization.string("Uncatalogued test label", language: .hebrew)
      == "Uncatalogued test label")
}

@Test func bridgeDownloadPluralUsesEnglishNumericOneAndHebrewNativeForms() {
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 1, table: "Bridge", language: .english)
      == "Closing the browser will cancel 1 active download.")
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 3, table: "Bridge", language: .english)
      == "Closing the browser will cancel 3 active downloads.")
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 0, table: "Bridge", language: .hebrew)
      == "הסגירה תבטל 0 הורדות פעילות.")
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 1, table: "Bridge", language: .hebrew)
      == "הסגירה תבטל הורדה פעילה אחת.")
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 2, table: "Bridge", language: .hebrew)
      == "הסגירה תבטל שתי הורדות פעילות.")
  #expect(
    BrowserLocalization.plural("%d active downloads", count: 3, table: "Bridge", language: .hebrew)
      == "הסגירה תבטל 3 הורדות פעילות.")
}
