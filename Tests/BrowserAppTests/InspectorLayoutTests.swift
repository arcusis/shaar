// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorLayoutTests {
  @Test func changingTheLockedElementClearsAndHoverDoesNot() {
    #expect(InspectorLayoutModel.shouldClear(pinned: 1, locked: 2))
    #expect(!InspectorLayoutModel.shouldClear(pinned: 1, locked: 1))
    #expect(!InspectorLayoutModel.shouldClear(pinned: 1, locked: nil))
    #expect(!InspectorLayoutModel.shouldClear(pinned: nil, locked: 4))
  }

  @Test func containerTitleKeepsTheIdAndTwoClasses() {
    #expect(
      InspectorLayoutContainer.title(tag: "section", elementID: "grid", classes: ["a", "b", "c"])
        == "section#grid.a.b")
    #expect(InspectorLayoutContainer.title(tag: "main", elementID: "", classes: []) == "main")
  }

  @Test func gridAreaNamesStayOutOfTheConfigUntilAsked() {
    let hidden = InspectorLayoutModel.gridHighlightConfig(
      lineNumbers: true, trackSizes: true, areaNames: false)
    #expect(hidden["showPositiveLineNumbers"] as? Bool == true)
    #expect(hidden["showTrackSizes"] as? Bool == true)
    #expect(hidden["showAreaNames"] as? Bool == false)
    let shown = InspectorLayoutModel.gridHighlightConfig(
      lineNumbers: false, trackSizes: false, areaNames: true)
    #expect(shown["showAreaNames"] as? Bool == true)
    #expect(shown["showPositiveLineNumbers"] as? Bool == false)
    let flex = InspectorLayoutModel.flexHighlightConfig()
    #expect(flex["containerBorder"] != nil)
    #expect(flex["rowGapSpace"] != nil)
    #expect(flex["columnGapSpace"] != nil)
    let color = InspectorLayoutModel.overlayColor()
    #expect(color["r"] as? Int == 139)
    #expect(color["g"] as? Int == 92)
    #expect(color["b"] as? Int == 246)
  }
}
