// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import XCTest

@testable import ArcusisBrowser

final class BrowserBackendSelectionTests: XCTestCase {
  func testArdiaRemainsDefault() {
    XCTAssertEqual(BrowserBackendSelection.choose(environment: [:], arguments: []), .ardia)
  }

  func testShaarRequiresExplicitEnvironmentOrFlag() {
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: ["SHAAR_ENGINE_BACKEND": "shaar"], arguments: []), .shaar)
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: [:], arguments: ["--shaar-engine-backend=shaar"]), .shaar)
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: ["SHAAR_ENGINE_BACKEND": "unknown"], arguments: []), .ardia)
  }

  func testExplicitShaarSelectionDoesNotFallBackWhenABIMissing() {
    XCTAssertThrowsError(
      try ARCShaarRuntime(frameworkURL: URL(fileURLWithPath: "/nonexistent-shaar-framework")))
  }
}
