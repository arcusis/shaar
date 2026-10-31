// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func spaceChromeTintMaintainsContrastForExtremeColors() {
  var space = BrowserSession.fresh().selectedSpace
  for red: UInt8 in [0, 255] {
    for green: UInt8 in [0, 255] {
      for blue: UInt8 in [0, 255] {
        space.customRGB = SpaceRGBColor(red: red, green: green, blue: blue)
        let tint = SpaceChromeTint(space: space)
        let light = luminance(tint.components(for: .light))
        let dark = luminance(tint.components(for: .dark))
        #expect((light + 0.05) / 0.05 >= 4.5)
        #expect(1.05 / (dark + 0.05) >= 4.5)
      }
    }
  }
}

@Test func spaceChromeTintUsesPresetAndCustomColor() {
  var space = BrowserSession.fresh().selectedSpace
  space.tint = .ocean
  let preset = SpaceChromeTint(space: space)
  #expect(preset.rgb == SpaceRGBColor(red: 0x6B, green: 0xAB, blue: 0xC9))
  space.customRGB = SpaceRGBColor(red: 1, green: 2, blue: 3)
  #expect(SpaceChromeTint(space: space).rgb == space.customRGB)
  #expect(SpaceChromeTint(space: space) != preset)
}

private func luminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
  func linear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
}
