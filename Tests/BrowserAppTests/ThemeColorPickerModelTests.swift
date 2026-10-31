// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

struct ThemeColorPickerModelTests {
  @Test func uncoloredProfilesStartTheSharedPickerFromTheFirstPreset() {
    let draft = ProfileColorChoice.none.draft
    #expect(draft.tint == .lavender)
    #expect(draft.customRGB == nil)
    #expect(draft.canSubmit)

    let custom = SpaceRGBColor(red: 12, green: 34, blue: 56)
    #expect(ProfileColorChoice(tint: .rose, customRGB: custom).draft.color == custom)
    let forest = SpaceTintRGB.color(for: .forest)
    #expect(ProfileColorChoice(tint: .forest).draft.hexValue == forest.hex)
  }

  @Test func profilesTakePresetsSwatchesAndValidHexFromThePicker() {
    var color = ProfileColorChoice.none
    var draft = color.draft
    draft.selectPreset(.ocean)
    color.apply(draft)
    #expect(color == ProfileColorChoice(tint: .ocean))

    let swatch = ThemeColorPalette.extras[0].color
    draft.setCustom(swatch)
    color.apply(draft)
    #expect(color.rgb == swatch)

    let accepted = draft.setHexDraft("#102030")
    #expect(accepted)
    color.apply(draft)
    #expect(color.rgb == SpaceRGBColor(red: 0x10, green: 0x20, blue: 0x30))
  }

  @Test func unparsableHexLeavesTheProfileColorUnchanged() {
    var color = ProfileColorChoice(tint: .rose)
    var draft = color.draft
    let accepted = draft.setHexDraft("#12345G")
    #expect(!accepted)
    color.apply(draft)
    #expect(color == ProfileColorChoice(tint: .rose))
  }

  @Test func profileSymbolsFallBackToThePersonGlyph() {
    #expect(BrowserProfile(name: "Personal").displaySymbol == "person.fill")
    #expect(BrowserProfile(name: "Work", symbol: "briefcase").displaySymbol == "briefcase")
  }
}
