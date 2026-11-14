// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite struct InspectorBoxEditTests {
  private func box() -> InspectorSelection.Box {
    InspectorSelection.Box(
      width: 180, height: 48, contentWidth: 136, contentHeight: 24,
      margin: ["8px", "12px", "8px", "12px"], border: Array(repeating: "2px", count: 4),
      padding: ["10px", "20px", "10px", "20px"])
  }

  @Test func bareNumbersGainPixelsAndOtherTextPassesThrough() {
    #expect(InspectorBoxEdit.cssValue("  12 ") == "12px")
    #expect(InspectorBoxEdit.cssValue("-4") == "-4px")
    #expect(InspectorBoxEdit.cssValue("0") == "0px")
    #expect(InspectorBoxEdit.cssValue("1em") == "1em")
    #expect(InspectorBoxEdit.cssValue("10%") == "10%")
    #expect(InspectorBoxEdit.cssValue("10px") == "10px")
    #expect(InspectorBoxEdit.cssValue("auto") == "auto")
    #expect(InspectorBoxEdit.cssValue("   ") == "")
  }

  @Test @MainActor func edgeAccessibilityLabelsIdentifyRegionAndSide() {
    #expect(
      InspectorBoxModel.edgeAccessibilityLabel(region: "margin", index: 0) == "Edit Margin Top")
    #expect(
      InspectorBoxModel.edgeAccessibilityLabel(region: "padding", index: 3) == "Edit Padding Left")
    #expect(
      InspectorBoxModel.edgeAccessibilityLabel(region: "border", index: 0)
        != InspectorBoxModel.edgeAccessibilityLabel(region: "border", index: 1))
    #expect(
      InspectorBoxModel.editorAccessibilityLabel(region: "content", index: 0) == "Edit Width")
    #expect(
      InspectorBoxModel.editorAccessibilityLabel(region: "content", index: 1) == "Edit Height")
    #expect(
      InspectorBoxModel.editorAccessibilityLabel(region: "border", index: 0) == "Edit Border Top")
  }

  @Test func editableTextStripsAPixelLength() {
    #expect(InspectorBoxEdit.editableText("10px") == "10")
    #expect(InspectorBoxEdit.editableText("0px") == "0")
    #expect(InspectorBoxEdit.editableText("10.5px") == "10.5")
    #expect(InspectorBoxEdit.editableText("1em") == "1em")
    #expect(InspectorBoxEdit.editableText("10%") == "10%")
    #expect(InspectorBoxEdit.draft("0px") == "0")
    #expect(InspectorBoxEdit.draft("10px") == "10")
    #expect(InspectorBoxEdit.draft(for: box(), edge: "padding0") == "10")
  }

  @Test func submissionNamesTheEdgeAndSkipsAnUnchangedValue() {
    let sample = box()
    #expect(
      InspectorBoxEdit.submission(region: "padding", index: 0, typed: "24", box: sample)
        == .init(property: "padding-top", value: "24px"))
    #expect(
      InspectorBoxEdit.submission(region: "padding", index: 0, typed: "10", box: sample) == nil)
    #expect(
      InspectorBoxEdit.submission(region: "padding", index: 0, typed: "", box: sample)
        == .init(property: "padding-top", value: ""))
    #expect(
      InspectorBoxEdit.submission(region: "margin", index: 1, typed: "1em", box: sample)
        == .init(property: "margin-right", value: "1em"))
    #expect(
      InspectorBoxEdit.submission(region: "border", index: 2, typed: "4", box: sample)
        == .init(property: "border-bottom-width", value: "4px"))
    #expect(
      InspectorBoxEdit.submission(region: "content", index: 0, typed: "200", box: sample)
        == .init(property: "width", value: "200px"))
    #expect(
      InspectorBoxEdit.submission(region: "content", index: 1, typed: "24", box: sample) == nil)
    #expect(
      InspectorBoxEdit.submission(edge: "content1", typed: "", box: sample)
        == .init(property: "height", value: ""))
    #expect(InspectorBoxEdit.submission(region: "gap", index: 0, typed: "4", box: sample) == nil)
    #expect(InspectorBoxEdit.property(region: "padding", index: 4) == nil)
    #expect(InspectorBoxEdit.property(region: "content", index: 2) == nil)
  }
}
