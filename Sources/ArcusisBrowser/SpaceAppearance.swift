// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

extension BrowserSpace {
  var themeColor: Color {
    guard let customRGB else { return tint.color }
    return Color(
      .sRGB,
      red: Double(customRGB.red) / 255,
      green: Double(customRGB.green) / 255,
      blue: Double(customRGB.blue) / 255,
      opacity: 1)
  }
}

struct SpaceChromeTint: Equatable {
  let rgb: SpaceRGBColor

  init(space: BrowserSpace) {
    rgb = space.customRGB ?? SpaceTintRGB.color(for: space.tint)
  }

  func components(for scheme: ColorScheme) -> (red: Double, green: Double, blue: Double) {
    let base = scheme == .dark ? 0.08 : 0.88
    let strength = scheme == .dark ? 0.14 : 0.12
    return (
      base + strength * Double(rgb.red) / 255,
      base + strength * Double(rgb.green) / 255,
      base + strength * Double(rgb.blue) / 255
    )
  }

  func color(for scheme: ColorScheme) -> Color {
    let value = components(for: scheme)
    return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1)
  }
}

enum SpaceEditorSavePolicy {
  static func isDisabled(name: String, appearance: ThemeColorDraft) -> Bool {
    !appearance.canSubmit || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

enum SpaceTintRGB {
  static func color(for tint: SpaceTint) -> SpaceRGBColor {
    switch tint {
    case .lavender: SpaceRGBColor(red: 0xA8, green: 0x99, blue: 0xD4)
    case .ocean: SpaceRGBColor(red: 0x6B, green: 0xAB, blue: 0xC9)
    case .rose: SpaceRGBColor(red: 0xCF, green: 0x87, blue: 0x9C)
    case .forest: SpaceRGBColor(red: 0x70, green: 0xA6, blue: 0x85)
    }
  }
}
