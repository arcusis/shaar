// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Basic browsing renderer capture evidence")
struct BasicBrowsingProbeTests {
  @Test func blackCaptureFailsAndColoredPageCapturePasses() throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    var pixel: [UInt] = [0, 0, 0, 255]
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide { bitmap.setPixel(&pixel, atX: x, y: y) }
    }
    #expect(!BasicBrowsingProbe.containsNonBlackPixels(bitmap))

    pixel = [32, 96, 160, 255]
    bitmap.setPixel(&pixel, atX: 5, y: 7)
    #expect(BasicBrowsingProbe.containsNonBlackPixels(bitmap))
  }
}
