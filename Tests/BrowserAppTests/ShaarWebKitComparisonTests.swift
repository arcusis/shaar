// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite(.serialized) @MainActor struct ShaarWebKitComparisonTests {
  @Test func differenceTilesLocateOnlyChangedRegion() {
    let chromium = image(changed: false)
    let webKit = image(changed: true)
    #expect(
      ShaarWebKitImageDiff.tiles(
        chromium: chromium, webKit: chromium, viewport: CGSize(width: 64, height: 64)
      ).isEmpty)
    #expect(
      ShaarWebKitImageDiff.tiles(
        chromium: chromium, webKit: webKit, viewport: CGSize(width: 64, height: 64))
        == [CGRect(x: 32, y: 0, width: 32, height: 32)])
  }

  @Test func onlyWebKitErrorsMissingFromChromiumAreShown() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let model = ShaarWebKitComparisonModel(target: target)
    model.open(inspector: nil)
    model.receive(["kind": "error", "message": "Shared failure"])
    model.receive(["kind": "error", "message": "WebKit layout error"])
    let chromium: [ShaarDevToolsEvent] = [
      .console(
        ShaarConsoleEvent(
          id: UUID(), level: .error, message: "shared failure", source: nil))
    ]
    #expect(model.safariOnlyErrors(comparedWith: chromium) == ["WebKit layout error"])
    model.close()
    #expect(model.safariOnlyErrors(comparedWith: chromium).isEmpty)
  }

  @Test func webKitConsoleErrorIsCapturedOffscreen() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let preview = ShaarWebKitComparisonPreview(
      chromiumPNG: Data(),
      webKitHTML: "<script>console.error('WebKit script error')</script>",
      viewport: CGSize(width: 400, height: 300), differenceTiles: [], webKitErrors: [])
    let model = ShaarWebKitComparisonModel(target: target, preview: preview)
    model.open(inspector: nil)
    for _ in 0..<40 where model.webKitErrors.isEmpty {
      _ = try? await model.webView?.evaluateJavaScript("document.readyState")
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.webKitErrors == ["WebKit script error"])
    model.close()
  }

  private func image(changed: Bool) -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<64 {
      for x in 0..<64 {
        var pixel =
          changed && x >= 32 && y < 32
          ? [0, 0, 255, 255] : [255, 0, 0, 255]
        bitmap.setPixel(&pixel, atX: x, y: y)
      }
    }
    return bitmap.representation(using: .png, properties: [:])!
  }
}
