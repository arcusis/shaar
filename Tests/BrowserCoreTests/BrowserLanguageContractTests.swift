// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest

@testable import BrowserCore

final class BrowserLanguageContractTests: XCTestCase {
  func testPersistedIdentifiersRemainStableAndSupportedLanguagesExcludeSystemDefault() {
    XCTAssertEqual(BrowserLanguage.systemDefault.rawValue, "systemDefault")
    XCTAssertEqual(BrowserLanguage.english.rawValue, "en")
    XCTAssertEqual(BrowserLanguage.hebrew.rawValue, "he")
    XCTAssertEqual(BrowserLanguage.supported, [.english, .hebrew])
    XCTAssertEqual(
      BrowserLanguage.resolve(selection: .systemDefault, preferredLanguages: ["_he"]), .hebrew)
  }

  func testSelectionGetterReadsTemporaryArgumentValuesAndUsesSystemDefaultForInvalidOrMissing() {
    let defaults = UserDefaults.standard
    let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer {
      defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    }

    let key = BrowserLanguage.selectionDefaultsKey
    var arguments = originalArguments

    arguments[key] = BrowserLanguage.hebrew.rawValue
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    XCTAssertEqual(BrowserLanguage.selection, .hebrew)

    arguments[key] = BrowserLanguage.english.rawValue
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    XCTAssertEqual(BrowserLanguage.selection, .english)

    arguments[key] = "unsupported-language"
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    XCTAssertEqual(BrowserLanguage.selection, .systemDefault)

    arguments.removeValue(forKey: key)
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let persistentDomain =
      defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    let persistedChoice = persistentDomain[key] as? String
    XCTAssertEqual(
      BrowserLanguage.selection,
      persistedChoice.flatMap(BrowserLanguage.init(rawValue:)) ?? .systemDefault)
  }

  func testProcessBootstrapPreservesArgumentsAndChangesOnlyVolatileAppleLanguages() {
    let defaults = UserDefaults.standard
    let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let persistentDomain =
      defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    defer {
      defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    }

    let cachedLaunchLanguage = BrowserLanguage.currentLaunchLanguage
    var arguments = originalArguments
    arguments["BrowserLanguageContractTests.launchMarker"] = "preserved"
    arguments["AppleLanguages"] = ["fr"]
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

    BrowserLanguage.applyToCurrentProcess()

    var expectedArguments = arguments
    expectedArguments["AppleLanguages"] = [cachedLaunchLanguage.localeIdentifier]
    XCTAssertTrue(
      (defaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary).isEqual(
        expectedArguments as NSDictionary),
      "Bootstrap must preserve arguments and update AppleLanguages only.")
    let persistentDomainAfter =
      defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    XCTAssertTrue(
      (persistentDomainAfter as NSDictionary).isEqual(persistentDomain as NSDictionary),
      "Bootstrap must leave persistent preferences unchanged.")
  }

  func testLocalizationFormattingAcceptsStringIntegerAndDecimalArguments() {
    let formatted = BrowserLocalization.format(
      "Profile %@ has %d tabs at %.2f scale", language: .english,
      arguments: [.string("Studio"), .integer(7), .decimal(1.25)])

    XCTAssertEqual(formatted, "Profile Studio has 7 tabs at 1.25 scale")
  }

  func testProductMeaningUsesLaunchLanguageCatalog() {
    let expectedMeaning =
      BrowserLanguage.currentLaunchLanguage == .hebrew
      ? "שער — השער לאינטרנט" : "שער — the gateway to the internet"

    XCTAssertEqual(ProductIdentity.meaning, expectedMeaning)
  }

  func testUntitledBookmarkAndFolderUseLaunchLanguageCatalog() throws {
    let folderID = UUID()
    let bookmarkID = UUID()
    let tree = try BookmarkTree(
      profileID: UUID(),
      payload: [
        "bar": [
          "id": UUID().uuidString, "k": "f", "t": "Bar",
          "c": [
            ["id": folderID.uuidString, "k": "f", "t": "", "c": []],
            [
              "id": bookmarkID.uuidString, "k": "u", "t": "",
              "u": "https://example.com",
            ],
          ],
        ],
        "other": ["id": UUID().uuidString, "k": "f", "t": "Other", "c": []],
      ])
    let expectedFolder =
      BrowserLanguage.currentLaunchLanguage == .hebrew ? "תיקייה ללא שם" : "Untitled folder"
    let expectedBookmark =
      BrowserLanguage.currentLaunchLanguage == .hebrew ? "סימנייה ללא שם" : "Untitled bookmark"

    XCTAssertEqual(tree.items.first { $0.id == folderID }?.title, expectedFolder)
    XCTAssertEqual(tree.items.first { $0.id == bookmarkID }?.title, expectedBookmark)
  }

  func testWorkspaceFolderOwnershipErrorHasLocalizedDescriptionAndLeavesWorkspaceUnchanged() throws
  {
    let profiles = [BrowserProfile(name: "Personal"), BrowserProfile(name: "Work")]
    let sharedFolder = BrowserFolder(name: "Shared")
    let firstSpace = BrowserSpace(
      profileID: profiles[0].id, name: "Personal", symbol: "person", tint: .ocean,
      folders: [sharedFolder])
    let secondSpace = BrowserSpace(
      profileID: profiles[1].id, name: "Work", symbol: "briefcase", tint: .ocean)
    let session = try BrowserSession(
      profiles: profiles, spaces: [firstSpace, secondSpace], selectedSpaceID: firstSpace.id)
    var workspace = try BrowserWorkspace(session: session)
    var movedFolderSession = session
    movedFolderSession.spaces[0].folders.removeAll { $0.id == sharedFolder.id }
    movedFolderSession.spaces[1].folders.append(sharedFolder)
    let originalWorkspace = workspace

    XCTAssertThrowsError(
      try workspace.updateWindow(workspace.windows[0].id, session: movedFolderSession)
    ) { error in
      let expectedDescription =
        BrowserLanguage.currentLaunchLanguage == .hebrew
        ? "בסביבת העבודה יש שיוכים סותרים של חלונות, מרחבים, פרופילים או לשוניות."
        : "The workspace has conflicting window, Space, profile, or tab ownership."
      guard case .invalidState = error as? WorkspaceError else {
        XCTFail("Expected invalid workspace state")
        return
      }
      XCTAssertEqual((error as? LocalizedError)?.errorDescription, expectedDescription)
    }
    XCTAssertEqual(workspace, originalWorkspace)
  }
}
