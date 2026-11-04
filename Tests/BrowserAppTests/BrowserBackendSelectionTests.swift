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

  private func assertShaarOverrides(_ name: String) {
    let selector = NSSelectorFromString(name)
    let ardia = class_getInstanceMethod(ARCChromiumRuntime.self, selector)
    let shaar = class_getInstanceMethod(ARCShaarRuntime.self, selector)
    XCTAssertNotNil(ardia)
    XCTAssertNotNil(shaar)
    XCTAssertNotEqual(ardia, shaar, "Shaar must override \(name)")
  }
}
