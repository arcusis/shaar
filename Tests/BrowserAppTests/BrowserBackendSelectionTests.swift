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

  func testShaarOverridesDevToolsAndInspector() {
    for selector in [
      "devToolsViewForTabID:", "showDevToolsForTabID:", "closeDevToolsForTabID:",
      "beginInspectorForTabID:profileID:windowID:", "endInspectorForTabID:",
      "inspectorCall:params:tabID:profileID:windowID:completion:",
      "beginDeveloperSessionForTabID:profileID:windowID:",
      "endDeveloperSessionForTabID:profileID:windowID:",
      "developerCall:params:tabID:profileID:windowID:completion:",
    ] {
      assertShaarOverrides(selector)
    }
    for field in [
      "_shaarEngine", "_nextRequestID", "_shaarProfiles", "_shaarWindows",
      "_shaarTabs", "_shaarTabProfiles", "_shaarTabWindows",
    ] {
      XCTAssertNotNil(class_getInstanceVariable(ARCShaarRuntime.self, field), field)
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
