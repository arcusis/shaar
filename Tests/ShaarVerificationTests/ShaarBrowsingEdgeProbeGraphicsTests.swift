// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeGraphicsTests {
  @Test func webGLRequiresAValidPaintedPixel() {
    #expect(ShaarBrowsingEdgeProbe.webGLPixelIsPainted([51, 102, 153, 255]))
    #expect(!ShaarBrowsingEdgeProbe.webGLPixelIsPainted([0, 0, 0, 255]))
    #expect(!ShaarBrowsingEdgeProbe.webGLPixelIsPainted([0, 0, 0, 0]))
    #expect(!ShaarBrowsingEdgeProbe.webGLPixelIsPainted([51, 102, 153]))
    #expect(!ShaarBrowsingEdgeProbe.webGLPixelIsPainted([51, 102, 256, 255]))
  }
}
