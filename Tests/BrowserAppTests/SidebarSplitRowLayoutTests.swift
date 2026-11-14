// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarSplitRowLayoutTests {
  @Test func splitSegmentsActivateWithReturnAndSpace() {
    #expect(SidebarSplitRow.isActivationKey(.return))
    #expect(SidebarSplitRow.isActivationKey(.space))
    #expect(!SidebarSplitRow.isActivationKey(.leftArrow))
  }

  @Test func hoverAnimationRespectsReduceMotion() {
    #expect(SidebarSplitRow.hoverAnimation(systemSetting: true, override: nil) == nil)
    #expect(SidebarSplitRow.hoverAnimation(systemSetting: false, override: true) == nil)
    #expect(SidebarSplitRow.hoverAnimation(systemSetting: true, override: false) == nil)
    #expect(SidebarSplitRow.hoverAnimation(systemSetting: false, override: false) != nil)
    #expect(SidebarSplitRow.hoverAnimation(systemSetting: false, override: nil) != nil)
  }

  @Test func keyboardActivationRunsSplitSelection() {
    var selections = 0
    let activate = SidebarSplitRow.keyboardActivationAction { selections += 1 }
    #expect(activate() == .handled)
    #expect(selections == 1)
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
