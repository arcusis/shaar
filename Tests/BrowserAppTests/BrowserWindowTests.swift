// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserWindowTests {
  @Test func builtInSpaceTintsKeepTheirSidebarPaletteColors() throws {
    let colors: [(SpaceTint, Double, Double, Double)] = [
      (.lavender, 0.66, 0.60, 0.83),
      (.ocean, 0.42, 0.67, 0.79),
      (.rose, 0.81, 0.53, 0.61),
      (.forest, 0.44, 0.65, 0.52),
    ]

    for (tint, red, green, blue) in colors {
      let color = try #require(NSColor(tint.color).usingColorSpace(.deviceRGB))
      #expect(abs(color.redComponent - red) < 0.001)
      #expect(abs(color.greenComponent - green) < 0.001)
      #expect(abs(color.blueComponent - blue) < 0.001)
    }
  }
}
