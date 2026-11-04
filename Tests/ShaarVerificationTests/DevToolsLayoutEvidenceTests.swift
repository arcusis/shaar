// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite @MainActor struct DevToolsLayoutEvidenceTests {
  @Test func rememberedDockAcceptsOnePointRoundingButRejectsGeometryChanges() {
    let initial = NSRect(x: 0, y: 0, width: 428, height: 660)
    #expect(
      DevToolsProbe.rememberedDockFrameMatches(
        initial, NSRect(x: 0, y: 0, width: 429, height: 660)))
    #expect(
      !DevToolsProbe.rememberedDockFrameMatches(
        initial, NSRect(x: 0, y: 0, width: 431, height: 660)))
    #expect(!DevToolsProbe.rememberedDockFrameMatches(initial, nil))
  }
}
