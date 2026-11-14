// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func packagedCoreResourcesResolveWithoutBuilderScratchDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let app = root.appendingPathComponent("Fixture.app")
  let resources = app.appendingPathComponent("Contents/Resources")
  let package = resources.appendingPathComponent("ArcusisBrowser_BrowserCore.bundle")
  try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
  let info = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "test.resources", "CFBundlePackageType": "APPL"],
    format: .xml, options: 0)
  try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
  try info.write(to: package.appendingPathComponent("Info.plist"))
  let host = try #require(Bundle(url: app))
  let selected = BrowserLocalization.resourceBundle(in: host) {
    Issue.record("Packaged resource lookup reached the builder fallback")
    return .main
  }
  #expect(selected.bundleURL.standardizedFileURL == package.standardizedFileURL)
}

@Test func packagedAppSkipsSwiftPMFallbackWhenResourceBundleIsMissing() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let app = root.appendingPathComponent("Fixture.app")
  let contents = app.appendingPathComponent("Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let info = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "test.resources", "CFBundlePackageType": "APPL"],
    format: .xml, options: 0)
  try info.write(to: contents.appendingPathComponent("Info.plist"))
  let host = try #require(Bundle(url: app))
  var usedFallback = false
  let selected = PackagedResourceBundle.resolve(named: "ArcusisBrowser_BrowserCore", in: host) {
    usedFallback = true
    return .main
  }
  #expect(selected == nil)
  #expect(!usedFallback)
}

@Test func developmentCoreResourcesUseSwiftPMFallbackWhenHostHasNoPackage() {
  var usedFallback = false
  let selected = BrowserLocalization.resourceBundle(in: Bundle(for: NSObject.self)) {
    usedFallback = true
    return .main
  }
  #expect(usedFallback)
  #expect(selected == .main)
}

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

@Test func nativHasItsHebrewDisplayName() {
  #expect(BrowserLocalization.string("Nativ", table: "Shell", language: .english) == "Nativ")
  #expect(BrowserLocalization.string("Nativ", table: "Shell", language: .hebrew) == "נתיב")
}

@Test func pasteAndGoMenuTitleHasHebrewLocalization() {
  #expect(BrowserLocalization.string("Paste and Go", table: "Shell", language: .english) == "Paste and Go")
  #expect(BrowserLocalization.string("Paste and Go", table: "Shell", language: .hebrew) == "הדבקה ומעבר")
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

@Test func missingCatalogPreservesFallbackKeyInBothLanguages() {
  for language in [BrowserLanguage.english, .hebrew] {
    #expect(
      BrowserLocalization.string("Personal", table: "__missing_catalog__", language: language)
        == "Personal")
  }
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

@Test func agentBridgeValidationAndConnectionLabelsHaveHebrewForms() {
  #expect(
    BrowserLocalization.string(
      "Agent control requires a web page.", table: "Shell", language: .hebrew)
      == "שליטת סוכן זמינה רק בדפי אינטרנט.")
  #expect(
    BrowserLocalization.format(
      "Local agent %d", table: "Shell", language: .hebrew, arguments: [.integer(2)])
      == "סוכן מקומי 2")
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

@Test func browserImportPreviewLabelsLocalizeKindsAndPreserveBrowserBrandNames() {
  for language in [BrowserLanguage.english, .hebrew] {
    let bookmark = BrowserLocalization.string("Bookmark", table: "Panels", language: language)
    let history = BrowserLocalization.string("History", table: "Panels", language: language)
    let source = BrowserLocalization.format(
      "From %@", table: "Panels", language: language, arguments: [.string("Chrome")])
    let readableSource = source.replacingOccurrences(of: "\u{2068}", with: "")
      .replacingOccurrences(of: "\u{2069}", with: "")
    if language == .english {
      #expect(bookmark == "Bookmark")
      #expect(history == "History")
      #expect(readableSource == "From Chrome")
    } else {
      #expect(bookmark == "סימנייה")
      #expect(history == "היסטוריה")
      #expect(readableSource == "מ־Chrome")
    }
  }
}

@Test func importFailuresExplainProblemsInEnglishAndHebrew() {
  #expect(
    BrowserImport.ImportError.unsupported.description(language: .english)
      == "Choose a Chrome, Edge, Brave, Arc, Safari, or Firefox profile folder or bookmark export.")
  #expect(
    BrowserImport.ImportError.privateProfile.description(language: .english)
      == "Private browser profiles cannot be imported. Choose a regular profile.")
  #expect(
    BrowserImport.ImportError.databaseUnavailable("fixture").description(language: .english)
      == "The selected browser history database could not be read safely.")
  #expect(
    BrowserImport.ImportError.tooManyRows.description(language: .english)
      == "The selected browser profile contains more data than can be imported at once.")
  #expect(
    BrowserImport.ImportError.unsupported.description(language: .hebrew)
      == "בחרו תיקיית פרופיל או קובץ ייצוא סימניות של Chrome, Edge, Brave, Arc, Safari או Firefox.")
  #expect(
    BrowserImport.ImportError.privateProfile.description(language: .hebrew)
      == "אי אפשר לייבא פרופילים פרטיים של דפדפן. בחרו פרופיל רגיל.")
  #expect(
    BrowserImport.ImportError.databaseUnavailable("fixture").description(language: .hebrew)
      == "לא ניתן לקרוא בבטחה את מסד נתוני ההיסטוריה של הדפדפן שנבחר.")
  #expect(
    BrowserImport.ImportError.tooManyRows.description(language: .hebrew)
      == "פרופיל הדפדפן שנבחר מכיל יותר נתונים ממה שניתן לייבא בבת אחת.")
}
