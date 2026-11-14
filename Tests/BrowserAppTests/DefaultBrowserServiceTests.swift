// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DefaultBrowserServiceTests {
  @Test func firstRunDefaultBrowserFailureUsesHebrewRecoveryCopy() {
    #expect(
      FirstRunSetupView.defaultBrowserFailure(language: .hebrew)
        == "לא ניתן להגדיר את Shaar כדפדפן ברירת המחדל.")
  }

  @Test func bundleWithoutAnIdentifierIsNeverReportedAsDefault() {
    let application = FileManager.default.temporaryDirectory
      .appending(path: "Missing-\(UUID().uuidString).app")

    #expect(!DefaultBrowserService.isDefault(application: application))
  }
}
