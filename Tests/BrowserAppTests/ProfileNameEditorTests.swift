// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileNameEditorTests: XCTestCase {
  func testSaveValueTrimsWhitespaceAndNewlines() {
    XCTAssertEqual(ProfileNameEditor.trimmedName(" \n Work profile \t\n"), "Work profile")
  }

  func testSaveValuePreservesInteriorWhitespace() {
    XCTAssertEqual(ProfileNameEditor.trimmedName("Work profile"), "Work profile")
  }

  func testEditorTitleIsVoiceOverHeading() {
    XCTAssertTrue(ProfileNameEditor.headingTraits.contains(.isHeader))
  }
}
