// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite struct PrivateMultiTabEvidenceTests {
  @Test func liveTabAuditRequiresOwnedWebContentsAndExpectedCount() {
    let valid: [AnyHashable: Any] = [
      "sourceIsRegular": true,
      "contextIsPrivate": true,
      "contextDistinct": true,
      "allWindowsUsePrivateActiveProfile": true,
      "allTabsInNativeProfileBrowser": true,
      "allWindowsDisplayOwnedWebContents": true,
      "visibleNativeViewportCount": 1,
      "tabCount": 3,
    ]
    #expect(PrivateMultiTabEvidence.liveTabAudit(valid, tabCount: 3))
    #expect(!PrivateMultiTabEvidence.liveTabAudit(valid, tabCount: 2))
    #expect(!PrivateMultiTabEvidence.liveTabAudit(nil, tabCount: 3))
    for key in valid.keys {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(!PrivateMultiTabEvidence.liveTabAudit(missing, tabCount: 3))
    }
  }

  @Test func shellAuditRequiresAttachedLayerBackedPage() {
    let valid: [String: Any] = [
      "stage": "tab-0", "containerCount": 1, "layerBacked": [true],
      "attached": true, "attachedInWindow": true, "nativeHidden": false,
      "rawWindowSibling": false,
    ]
    #expect(PrivateMultiTabEvidence.liveShellAudit(valid, stage: "tab-0"))
    #expect(!PrivateMultiTabEvidence.liveShellAudit(valid, stage: "search"))
    for key in valid.keys {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(!PrivateMultiTabEvidence.liveShellAudit(missing, stage: "tab-0"))
    }
  }

  @Test func blankPrivateTabCannotCoverTheSwiftUIShell() {
    let valid: [String: Any] = [
      "stage": "first-blank", "nativeViewPresent": true,
      "rawWindowSibling": false, "containerCount": 0,
    ]
    #expect(PrivateMultiTabEvidence.blankShellAudit(valid))
    for key in valid.keys {
      var invalid = valid
      invalid.removeValue(forKey: key)
      #expect(!PrivateMultiTabEvidence.blankShellAudit(invalid))
    }
    var covered = valid
    covered["rawWindowSibling"] = true
    #expect(!PrivateMultiTabEvidence.blankShellAudit(covered))
  }

  @Test func searchEvidenceRequiresRenderedResultsFromExpectedHost() {
    let valid: [String: Any] = [
      "host": "search.example", "ready": "complete", "textLength": 101,
    ]
    #expect(PrivateMultiTabEvidence.liveSearch(valid, host: "search.example"))
    #expect(!PrivateMultiTabEvidence.liveSearch(valid, host: "other.example"))
    #expect(
      !PrivateMultiTabEvidence.liveSearch(
        ["host": "search.example", "ready": "loading", "textLength": 101], host: "search.example"))
    #expect(
      !PrivateMultiTabEvidence.liveSearch(
        ["host": "search.example", "ready": "complete", "textLength": 100], host: "search.example"))
  }

  @Test func bitmapLightSamplesDistinguishWhiteFromBlack() throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    var white: [UInt] = [255, 255, 255, 255]
    var black: [UInt] = [0, 0, 0, 255]
    for y in 0..<18 {
      for x in 0..<18 { bitmap.setPixel(&white, atX: x, y: y) }
    }
    #expect(PrivateMultiTabEvidence.lightSamples(bitmap) == 64)
    for y in 0..<18 {
      for x in 0..<18 { bitmap.setPixel(&black, atX: x, y: y) }
    }
    #expect(PrivateMultiTabEvidence.lightSamples(bitmap) == 0)
  }
}
