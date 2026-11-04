// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ObjectiveC
import XCTest

final class BrowserBackendSelectionTests: XCTestCase {
  func testShaarOverridesProfileLoading() {
    assertShaarOverrides("loadProfileID:completion:")
  }

  func testShaarOverridesWindowAndTabHosting() {
    for selector in [
      "createWindowID:error:", "closeWindowID:",
      "openTabID:profileID:windowID:url:error:", "closeTabID:",
      "hostViewForWindowID:", "viewForTabID:", "activateTabID:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesPrivateBrowsingAndPrivacy() {
    for selector in [
      "privatePrivacyAvailable", "privateContextEnabled", "isPrivateIdentity:",
      "privateIdentityOccupied:",
      "createPrivateContextID:sourceProfileID:completion:",
      "createPrivateWindowID:contextID:tabID:url:error:",
      "openPrivateTabID:windowID:contextID:url:error:",
      "selectPrivateTabID:windowID:contextID:",
      "focusPrivateTabID:windowID:contextID:",
      "closePrivateTabID:windowID:contextID:completion:",
      "navigatePrivateTabID:windowID:contextID:url:",
      "reloadPrivateTabID:windowID:contextID:",
      "goBackPrivateTabID:windowID:contextID:",
      "goForwardPrivateTabID:windowID:contextID:",
      "windowForPrivateWindowID:contextID:",
      "hostViewForPrivateWindowID:contextID:",
      "viewForPrivateTabID:windowID:contextID:",
      "closePrivateWindowID:contextID:completion:",
      "releasePrivateContextID:",
      "privatePrivacyStatusForContextID:completion:",
      "setPrivateCookieSettingForContextID:origin:value:completion:",
      "setPrivateTrackerAllowanceForContextID:origin:allow:completion:",
      "privateCookiesForTabID:windowID:contextID:origin:completion:",
      "setPrivateCookiesAllowed:tabID:windowID:contextID:origin:completion:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  private func assertShaarOverrides(_ name: String) {
    let selector = NSSelectorFromString(name)
    let ardia = class_getInstanceMethod(ARCChromiumRuntime.self, selector)
    let shaar = class_getInstanceMethod(ARCShaarRuntime.self, selector)
    XCTAssertNotNil(ardia)
    XCTAssertNotNil(shaar)
    XCTAssertNotEqual(ardia, shaar, "Shaar must override \(name)")
  }
}
