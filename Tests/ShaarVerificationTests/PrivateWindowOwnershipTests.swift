// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import ShaarVerification

final class PrivateWindowOwnershipTests: XCTestCase {
  func testNativeFixtureOwnsDetachedPrivateViews() {
    let audit: [String: Any] = [
      "allTabsInNativeProfileBrowser": true,
      "allTabsDetachedFromHostView": true,
      "allWindowsUsePrivateActiveProfile": true,
      "allWindowsSelectOwnedWebContents": true,
    ]
    XCTAssertTrue(PrivateWindowOwnership.nativeFixtureIsOwned(audit))
  }

  func testNativeFixtureRejectsDirectHostAttachment() {
    let audit: [String: Any] = [
      "allTabsInNativeProfileBrowser": true,
      "allTabsDetachedFromHostView": false,
      "allWindowsUsePrivateActiveProfile": true,
      "allWindowsSelectOwnedWebContents": true,
    ]
    XCTAssertFalse(PrivateWindowOwnership.nativeFixtureIsOwned(audit))
  }

  func testNativeFixtureRejectsUnownedSelection() {
    let audit: [String: Any] = [
      "allTabsInNativeProfileBrowser": true,
      "allTabsDetachedFromHostView": true,
      "allWindowsUsePrivateActiveProfile": true,
      "allWindowsSelectOwnedWebContents": false,
    ]
    XCTAssertFalse(PrivateWindowOwnership.nativeFixtureIsOwned(audit))
  }

  func testNativeFixtureRejectsNumericValuesForBooleanEvidence() {
    let audit: [String: Any] = [
      "allTabsInNativeProfileBrowser": NSNumber(value: 1),
      "allTabsDetachedFromHostView": true,
      "allWindowsUsePrivateActiveProfile": true,
      "allWindowsSelectOwnedWebContents": true,
    ]
    XCTAssertFalse(PrivateWindowOwnership.nativeFixtureIsOwned(audit))
  }
}
