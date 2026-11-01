// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore

/// The color being edited in a theme color picker: a preset tint or a custom color, plus the
/// hex text the user typed, which may not be a valid color yet.
struct ThemeColorDraft: Equatable {
  var tint: SpaceTint
  var customRGB: SpaceRGBColor?
  private(set) var hexValue: String
  private(set) var isHexValid = true

  init(tint: SpaceTint, customRGB: SpaceRGBColor?) {
    self.tint = tint
    self.customRGB = customRGB
    hexValue = customRGB?.hex ?? SpaceTintRGB.color(for: tint).hex
  }

  var color: SpaceRGBColor {
    customRGB ?? SpaceTintRGB.color(for: tint)
  }

  var canSubmit: Bool { isHexValid }

  mutating func selectPreset(_ value: SpaceTint) {
    tint = value
    customRGB = nil
    hexValue = SpaceTintRGB.color(for: value).hex
    isHexValid = true
  }

  mutating func setCustom(_ value: SpaceRGBColor) {
    customRGB = value
    hexValue = value.hex
    isHexValid = true
  }

  @discardableResult
  mutating func setHexDraft(_ value: String) -> Bool {
    hexValue = value
    guard let parsed = SpaceRGBColor(hex: value) else {
      isHexValid = false
      return false
    }
    setCustom(parsed)
    return true
  }

  @discardableResult
  mutating func setCustomComponents(red: Double, green: Double, blue: Double) -> Bool {
    let components = [red, green, blue]
    guard components.allSatisfy(\.isFinite) else {
      isHexValid = false
      return false
    }
    let channels = components.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
    setCustom(SpaceRGBColor(red: channels[0], green: channels[1], blue: channels[2]))
    return true
  }

  mutating func rejectColorInput() {
    isHexValid = false
  }
}

/// Named colors offered next to the preset tints wherever a Space or profile color is picked.
enum ThemeColorPalette {
  static let extras: [(name: String, color: SpaceRGBColor)] = [
    (SettingsL10n.string("White"), .init(red: 240, green: 234, blue: 228)),
    (SettingsL10n.string("Pink"), .init(red: 237, green: 152, blue: 180)),
    (SettingsL10n.string("Purple"), .init(red: 166, green: 112, blue: 160)),
    (SettingsL10n.string("Red"), .init(red: 238, green: 83, blue: 100)),
    (SettingsL10n.string("Orange"), .init(red: 255, green: 133, blue: 83)),
    (SettingsL10n.string("Yellow"), .init(red: 255, green: 215, blue: 90)),
    (SettingsL10n.string("Green"), .init(red: 54, green: 217, blue: 144)),
    (SettingsL10n.string("Blue"), .init(red: 109, green: 188, blue: 215)),
    (SettingsL10n.string("Slate"), .init(red: 103, green: 105, blue: 143)),
  ]
}
