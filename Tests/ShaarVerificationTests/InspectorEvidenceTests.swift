// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct InspectorEvidenceTests {
  @Test func assetReceiptPreservesObservedMetadataAndUnknowns() throws {
    #expect(InspectorProbe.assetReceipt(nil) is NSNull)
    var assets = InspectorAssetsData(
      images: [
        .init(
          index: 0, url: "https://example.com/a.png", renderedWidth: 128, renderedHeight: 96,
          naturalWidth: 64, naturalHeight: 48, transferSize: nil, bodySize: 512, mime: "image/png",
          frameID: "frame")
      ], svg: nil, svgTruncated: false)
    assets.fonts = [
      .init(url: "https://example.com/font.woff2", mime: "font/woff2", frameID: "frame")
    ]
    let receipt = try #require(InspectorProbe.assetReceipt(assets) as? [String: Any])
    let image = try #require((receipt["images"] as? [[String: Any]])?.first)
    #expect(image["naturalWidth"] as? Double == 64)
    #expect(image["renderedWidth"] as? Double == 128)
    #expect(image["mime"] as? String == "image/png")
    #expect(image["transferSize"] is NSNull)
    #expect((receipt["fontFiles"] as? [[String: String]])?.first?["mime"] == "font/woff2")
  }

  @Test func screenshotDimensionsRequireAnActualPNG() throws {
    #expect(InspectorProbe.captureDimensions(Data("not an image".utf8)) == nil)
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(InspectorProbe.captureDimensions(png) == CGSize(width: 20, height: 12))
    #expect(InspectorProbe.captureDimensions(png.prefix(12)) == nil)
  }

  @Test func reportRetainsPartialChecksAndFailureWithoutClaimingSuccess() throws {
    struct Failure: LocalizedError { var errorDescription: String? { "Renderer unavailable" } }
    let failed =
      try JSONSerialization.jsonObject(
        with: InspectorProbe.reportData(checks: ["hover"], error: Failure())) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["checks"] as? [String] == ["hover"])
    #expect(failed?["error"] as? String == "Renderer unavailable")
    let passed =
      try JSONSerialization.jsonObject(
        with: InspectorProbe.reportData(checks: ["hover", "lock"], error: nil)) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("Offscreen") == true)
  }
}
