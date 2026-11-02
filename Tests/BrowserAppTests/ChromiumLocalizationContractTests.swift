// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import XCTest

final class ChromiumLocalizationContractTests: XCTestCase {
  func testFrameworkLoadErrorsUseBridgeCatalogAndInvalidLanguageFallsBackToEnglish() throws {
    let launchLanguage = BrowserLanguage.currentLaunchLanguage.localeIdentifier
    defer {
      ARCConfigureLocalization(BrowserLocalization.resourceBundleURL, launchLanguage)
    }

    let temporaryRoot = FileManager.default.temporaryDirectory
      .appending(
        path: "ChromiumLocalizationContract-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let frameworkURL = temporaryRoot.appending(
      path: "Missing Chromium.framework", directoryHint: .isDirectory)

    let cases = [
      (language: "he", prefix: "לא ניתן לטעון את Chromium: "),
      (language: "en", prefix: "Cannot load Chromium: "),
      (language: "fr", prefix: "Cannot load Chromium: "),
    ]
    var diagnosticDetails: [String] = []

    for testCase in cases {
      ARCConfigureLocalization(BrowserLocalization.resourceBundleURL, testCase.language)

      XCTAssertThrowsError(try ARCChromiumRuntime(frameworkURL: frameworkURL)) { error in
        let bridgeError = error as NSError
        XCTAssertEqual(bridgeError.domain, "com.arcusis.browser.chromium")
        XCTAssertEqual(bridgeError.code, 1)
        XCTAssertTrue(bridgeError.localizedDescription.hasPrefix(testCase.prefix))

        let detail = String(bridgeError.localizedDescription.dropFirst(testCase.prefix.count))
        XCTAssertFalse(detail.isEmpty)
        XCTAssertTrue(detail.contains(frameworkURL.path))
        diagnosticDetails.append(detail)
      }
    }

    XCTAssertEqual(diagnosticDetails.count, cases.count)
    XCTAssertEqual(
      Set(diagnosticDetails).count, 1, "Localization must preserve loader diagnostic detail")
  }
}
