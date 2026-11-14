// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarSplitRowLayoutTests {
  @Test func splitPaneSegmentsActivateWithReturnAndSpace() {
    var activations = 0
    for key in [KeyEquivalent.return, .space] {
      #expect(
        SidebarSplitRow.keyboardActivation(for: key) { activations += 1 } == .handled)
    }
    #expect(activations == 2)
    #expect(SidebarSplitRow.keyboardActivation(for: .escape) {} == .ignored)
  }

  @Test func titlesRequireActualPaneWidthAfterHandleAndSpacing() {
    #expect(
      !SidebarSplitRow.showsTitles(
        totalWidth: 212, segmentCount: 3, hasStackDragHandle: true))
    #expect(
      SidebarSplitRow.showsTitles(
        totalWidth: 240, segmentCount: 3, hasStackDragHandle: true))
    #expect(
      SidebarSplitRow.showsTitles(
        totalWidth: 212, segmentCount: 3, hasStackDragHandle: false))
  }
}
