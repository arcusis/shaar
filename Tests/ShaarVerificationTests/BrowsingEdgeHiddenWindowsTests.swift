// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite
struct BrowsingEdgeHiddenWindowsTests {
  @Test func aVisibleNoteFailsTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: [],
      notes: [["kind": "visible", "class": "NSWindow", "title": "Leak"]])
    #expect(detail == "Visible during the run: Leak")
  }

  @Test func aWindowLeftUpFailsTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: ["Shaar"], notes: [])
    #expect(detail == "Still visible: Shaar")
  }

  @Test func anOpenPanelDoesNotFailTheRow() {
    let detail = browsingEdgeHiddenWindowsFailure(
      stillVisible: [],
      notes: [["kind": "open-panel", "class": "NSOpenPanel", "title": "Open"]])
    #expect(detail == nil)
  }
}
