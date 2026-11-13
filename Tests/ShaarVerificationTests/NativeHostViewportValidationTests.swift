// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite struct NativeHostViewportValidationTests {
  @Test func stableViewportAllowsOnePixelRoundingButRejectsRealResize() {
    let baseline = CGSize(width: 1200, height: 780)
    #expect(
      NativeHostViewportValidation.sameCSSSize(
        baseline, CGSize(width: 1201, height: 779)))
    #expect(
      NativeHostViewportValidation.sameCSSSize(
        baseline, CGSize(width: 1199, height: 781)))
    #expect(
      !NativeHostViewportValidation.sameCSSSize(
        baseline, CGSize(width: 1201.01, height: 780)))
    #expect(
      !NativeHostViewportValidation.sameCSSSize(
        baseline, CGSize(width: 1200, height: 781.01)))
  }
}
