// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite @MainActor struct PrivateMultiTabEvidenceTests {
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

  @Test func liveTabAuditRejectsJSONNumbersForBooleanFlags() throws {
    let base: [String: Any] = [
      "sourceIsRegular": true, "contextIsPrivate": true, "contextDistinct": true,
      "allWindowsUsePrivateActiveProfile": true, "allTabsInNativeProfileBrowser": true,
      "allWindowsDisplayOwnedWebContents": true, "visibleNativeViewportCount": 1,
      "tabCount": 1,
    ]
    let keys = [
      "sourceIsRegular", "contextIsPrivate", "contextDistinct",
      "allWindowsUsePrivateActiveProfile", "allTabsInNativeProfileBrowser",
      "allWindowsDisplayOwnedWebContents",
    ]
    for key in keys {
      var malformed = base
      malformed[key] = 1
      #expect(
        !PrivateMultiTabEvidence.liveTabAudit(
          try jsonObject(malformed) as [AnyHashable: Any], tabCount: 1))
    }
  }

  @Test func shellAttachmentRequiresTheNativePageAsAnActualSubview() {
    let container = NSView()
    let page = NSView()
    container.addSubview(page)
    #expect(PrivateMultiTabEvidence.pageIsAttached(page, to: container, retainedPage: page))

    page.removeFromSuperview()
    #expect(!PrivateMultiTabEvidence.pageIsAttached(page, to: container, retainedPage: page))
  }

  @Test func shellAuditRejectsJSONBooleanContainerCount() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "stage": "tab-0", "containerCount": true, "layerBacked": [true],
      "attached": true, "attachedInWindow": true, "nativeHidden": false,
      "rawWindowSibling": false,
    ] as [String: Any])
    let shellAudit = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(!PrivateMultiTabEvidence.liveShellAudit(shellAudit, stage: "tab-0"))
  }

  @Test func shellAuditRejectsJSONNumbersForBooleanEvidence() throws {
    let base: [String: Any] = [
      "stage": "tab-0", "containerCount": 1, "layerBacked": [true],
      "attached": true, "attachedInWindow": true, "nativeHidden": false,
      "rawWindowSibling": false,
    ]
    let invalid: [(String, Any)] = [
      ("attached", 1), ("attachedInWindow", 1), ("nativeHidden", 0),
      ("rawWindowSibling", 0), ("layerBacked", [1]),
    ]
    for (key, value) in invalid {
      var malformed = base
      malformed[key] = value
      #expect(
        !PrivateMultiTabEvidence.liveShellAudit(
          try jsonObject(malformed), stage: "tab-0"))
    }
  }

  @Test func liveTabCountsRejectBooleansFractionsAndStrings() {
    let base: [AnyHashable: Any] = [
      "sourceIsRegular": true,
      "contextIsPrivate": true,
      "contextDistinct": true,
      "allWindowsUsePrivateActiveProfile": true,
      "allTabsInNativeProfileBrowser": true,
      "allWindowsDisplayOwnedWebContents": true,
      "visibleNativeViewportCount": 1,
      "tabCount": 1,
    ]
    #expect(PrivateMultiTabEvidence.liveTabAudit(base, tabCount: 1))

    for (key, value) in [
      ("visibleNativeViewportCount", true as Any),
      ("visibleNativeViewportCount", 1.5 as Any),
      ("visibleNativeViewportCount", "1" as Any),
      ("tabCount", true as Any),
      ("tabCount", 1.5 as Any),
      ("tabCount", "1" as Any),
    ] {
      var invalid = base
      invalid[key] = value
      #expect(!PrivateMultiTabEvidence.liveTabAudit(invalid, tabCount: 1))
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

  @Test func splitShellAuditRequiresTwoVisibleAttachedPagesInTheWindow() {
    let valid: [String: Any] = [
      "stage": "split", "containerCount": 2,
      "attachedContainerCount": 2, "attachedPagesInWindowCount": 2,
      "visiblePagesInWindowCount": 2, "layerBacked": [true, true],
      "attached": true, "attachedInWindow": true, "nativeHidden": false,
      "rawWindowSibling": false,
    ]
    #expect(PrivateMultiTabEvidence.splitShellAudit(valid))
    for key in valid.keys {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(!PrivateMultiTabEvidence.splitShellAudit(missing))
    }
    var detachedPane = valid
    detachedPane["attachedPagesInWindowCount"] = 1
    #expect(!PrivateMultiTabEvidence.splitShellAudit(detachedPane))
    var hiddenPane = valid
    hiddenPane["visiblePagesInWindowCount"] = 1
    #expect(!PrivateMultiTabEvidence.splitShellAudit(hiddenPane))
  }

  @Test func blankPrivateTabCannotCoverTheSwiftUIShell() {
    let valid: [String: Any] = [
      "stage": "first-blank", "nativeViewPresent": true,
      "rawWindowSibling": false, "containerCount": 1,
      "layerBacked": [true], "attached": true,
      "attachedInWindow": true, "nativeHidden": false,
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
    var detached = valid
    detached["attachedInWindow"] = false
    #expect(!PrivateMultiTabEvidence.blankShellAudit(detached))
  }

  @Test func searchEvidenceRequiresRenderedResultsFromExpectedHost() {
    let valid: [String: Any] = [
      "host": "search.example", "ready": "complete", "textLength": 101,
    ]
    #expect(PrivateMultiTabEvidence.liveSearch(valid, host: "search.example"))
    var interactive = valid
    interactive["ready"] = "interactive"
    #expect(PrivateMultiTabEvidence.liveSearch(interactive, host: "search.example"))
    #expect(!PrivateMultiTabEvidence.liveSearch(valid, host: "other.example"))
    #expect(
      !PrivateMultiTabEvidence.liveSearch(
        ["host": "search.example", "ready": "loading", "textLength": 101], host: "search.example"))
    #expect(
      !PrivateMultiTabEvidence.liveSearch(
        ["host": "search.example", "ready": "complete", "textLength": 100], host: "search.example"))
    for invalidLength: Any in [true, 101.5, "101"] {
      #expect(!PrivateMultiTabEvidence.liveSearch([
        "host": "search.example", "ready": "complete", "textLength": invalidLength,
      ], host: "search.example"))
    }
    #expect(!PrivateMultiTabEvidence.liveSearch(
      ["host": "", "ready": "complete", "textLength": 101], host: ""))
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

private func jsonObject(_ object: [String: Any]) throws -> [String: Any] {
  let data = try JSONSerialization.data(withJSONObject: object)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
