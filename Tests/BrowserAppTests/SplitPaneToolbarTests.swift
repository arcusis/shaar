// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SplitPaneToolbarTests {
  @Test func splitLayoutAccessibilityValueReportsPresetAndPaneCount() {
    let count = ShellL10n.plural("%d tabs", count: 3)
    #expect(
      SplitLayoutControls.accessibilityValue(preset: .mainLeading, paneCount: 3)
        == "\(SplitLayoutPreset.mainLeading.title), \(count)")
    #expect(
      SplitLayoutControls.accessibilityValue(preset: nil, paneCount: 1)
        == ShellL10n.plural("%d tabs", count: 1))
  }
}
