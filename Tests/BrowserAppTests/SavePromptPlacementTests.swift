// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SavePromptPlacementTests {
  @Test func promptOriginStaysWithinTheVisibleScreenFrame() {
    let visibleFrame = NSRect(x: 40, y: 30, width: 1440, height: 900)
    let panelSize = NSSize(width: 360, height: 196)
    let upperRight = SavePromptPlacement.clampedOrigin(
      NSPoint(x: 1400, y: 890), panelSize: panelSize, visibleFrame: visibleFrame)
    let lowerLeft = SavePromptPlacement.clampedOrigin(
      NSPoint(x: -200, y: -200), panelSize: panelSize, visibleFrame: visibleFrame)

    #expect(upperRight == NSPoint(x: 1120, y: 734))
    #expect(lowerLeft == NSPoint(x: 40, y: 30))
    #expect(visibleFrame.contains(NSRect(origin: upperRight, size: panelSize)))
    #expect(visibleFrame.contains(NSRect(origin: lowerLeft, size: panelSize)))
  }
}
