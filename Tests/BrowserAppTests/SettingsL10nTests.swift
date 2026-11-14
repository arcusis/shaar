// This file is part of Shaar.
// Copyright (c) Arcusis, LLC. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing
import XCTest

@testable import ArcusisBrowser

final class SettingsL10nTests: XCTestCase {
  func testNoticeFormatsWorkspaceSaveFailureAndPreservesDetail() {
    let detail = "permission denied"
    let notice = SettingsL10n.notice("Window changes could not be saved. \(detail)")
    let expected = BrowserLocalization.format(
      "Window changes could not be saved. %@", table: "Settings",
      language: .currentLaunchLanguage, arguments: [.string(detail)])

    XCTAssertEqual(notice, expected)
  }

  func testNoticeLocalizesOtherKnownSettingsMessages() {
    XCTAssertEqual(
      SettingsL10n.notice("Could not delete the profile. Try again."),
      SettingsL10n.string("Could not delete the profile. Try again."))
  }
}

struct HebrewWorkspaceSaveNoticeTests {
  @Test func noticeDoesNotExposeEnglishFailureDetails() {
    #expect(
      SettingsL10n.notice(
        "Window changes could not be saved. The file is locked.", language: .hebrew)
        == "לא ניתן לשמור את שינויי החלונות. כדאי לנסות שוב.")
  }
}
