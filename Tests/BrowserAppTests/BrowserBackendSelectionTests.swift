// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ObjectiveC
import XCTest

final class BrowserBackendSelectionTests: XCTestCase {
  func testShaarOverridesProfileLoading() {
    let selector = NSSelectorFromString("loadProfileID:completion:")
    let ardia = class_getInstanceMethod(ARCChromiumRuntime.self, selector)
    let shaar = class_getInstanceMethod(ARCShaarRuntime.self, selector)
    XCTAssertNotNil(ardia)
    XCTAssertNotNil(shaar)
    XCTAssertNotEqual(ardia, shaar)
  }
}
