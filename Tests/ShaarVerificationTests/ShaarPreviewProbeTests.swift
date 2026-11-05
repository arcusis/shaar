// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@MainActor
@Suite struct ShaarPreviewProbeTests {
  @Test func missingProbeInputsFailBeforeStartingTheEngine() {
    #expect(ShaarPreviewProbe.run(arguments: []) == 1)
    #expect(
      ShaarPreviewProbe.run(arguments: [
        "--probe-output", "/tmp/shaar-preview-report.json",
      ]) == 1)
    #expect(
      ShaarPreviewProbe.run(arguments: [
        "--probe-output", "/tmp/shaar-preview-report.json", "--probe-data-dir",
        "/tmp/shaar-preview-data",
      ]) == 1)
  }

  @Test func pendingQuitProbeRequiresLoopbackHTTP() throws {
    let target = try ShaarPreviewProbe.pendingQuitTarget(arguments: [
      "--probe-pending-quit-url", "http://127.0.0.1:8080/stall",
    ])
    #expect(target?.absoluteString == "http://127.0.0.1:8080/stall")
    #expect(
      (try? ShaarPreviewProbe.pendingQuitTarget(arguments: [
        "--probe-pending-quit-url", "https://example.com/stall",
      ])) == nil)
  }

  @Test func blankRendererCaptureCannotPassPaintCheck() {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var white: [UInt] = [255, 255, 255, 255]
    for x in 0..<100 {
      for y in 0..<100 { bitmap.setPixel(&white, atX: x, y: y) }
    }
    #expect(ShaarPreviewProbe.paintMatchesFixture(bitmap) == false)
    var blue: [UInt] = [0x16, 0x78, 0xC6, 255]
    for x in 35..<65 {
      for y in 35..<65 {
        bitmap.setPixel(&blue, atX: x, y: y)
      }
    }
    #expect(ShaarPreviewProbe.paintMatchesFixture(bitmap))
  }

  @Test func previewReportRequiresPaintEvidence() {
    let checks = [
      "openTab", "paint", "navigate", "backForward", "devTools", "newWindow",
      "privateWindow", "profilesSwitch", "extensions", "downloads",
    ]
    var results: [String: [String: Any]] = Dictionary(
      uniqueKeysWithValues: checks.map { ($0, ["status": "pass"]) })
    #expect(ShaarPreviewProbe.reportPasses(results))
    results.removeValue(forKey: "paint")
    #expect(!ShaarPreviewProbe.reportPasses(results))
    results["paint"] = ["status": "fail"]
    #expect(!ShaarPreviewProbe.reportPasses(results))
  }
}
