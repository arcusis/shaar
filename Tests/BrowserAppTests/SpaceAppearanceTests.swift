// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SpaceAppearanceTests {
  @Test func customThemeColorUsesItsStoredSRGBChannels() throws {
    var space = BrowserSession.fresh().selectedSpace
    space.customRGB = SpaceRGBColor(red: 18, green: 132, blue: 214)

    let color = try #require(NSColor(space.themeColor).usingColorSpace(.deviceRGB))

    #expect(abs(color.redComponent - 18.0 / 255) < 0.001)
    #expect(abs(color.greenComponent - 132.0 / 255) < 0.001)
    #expect(abs(color.blueComponent - 214.0 / 255) < 0.001)
    #expect(color.alphaComponent == 1)
  }
}
