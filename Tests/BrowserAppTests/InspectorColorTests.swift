// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func inspectorContrastUsesLinearSRGBAndCompositesAlpha() {
  let white = InspectorColor(css: "white", rgba: [1, 1, 1, 1])
  let black = InspectorColor(css: "black", rgba: [0, 0, 0, 1])
  #expect(black.contrast(on: white) == 21)
  #expect(white.contrast(on: white) == 1)
  let translucent = InspectorColor(css: "rgba(0,0,0,.5)", rgba: [0, 0, 0, 0.5])
  #expect(abs((translucent.contrast(on: white) ?? 0) - 3.976653) < 0.00001)
  let gray = InspectorColor(css: "#777", rgba: [119.0 / 255, 119.0 / 255, 119.0 / 255, 1])
  #expect(abs((gray.contrast(on: white) ?? 0) - 4.478089) < 0.0001)
  #expect(black.contrast(on: InspectorColor(css: "clear", rgba: [1, 1, 1, 0])) == nil)
}

@Test func inspectorFormatsColorsAndRejectsMalformedChannels() {
  let red = InspectorColor(css: "red", rgba: [1, 0, 0, 1])
  #expect(red.formatted(.hex) == "#FF0000")
  #expect(red.formatted(.rgb) == "rgb(255 0 0)")
  #expect(red.formatted(.oklch) == "oklch(62.8% 0.2577 29.23)")
  #expect(InspectorColor(css: "bad", rgba: [Double.nan, 0, 0, 1]).valid == false)
  #expect(InspectorColor(css: "bad", rgba: [0, 1]).valid == false)
  #expect(InspectorColor(css: "bad", rgba: [0, 0, 0, 2]).valid == false)
}
