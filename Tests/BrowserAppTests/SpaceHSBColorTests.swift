// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import CoreGraphics
import Testing

@testable import ArcusisBrowser

struct SpaceHSBColorTests {
  private let field = CGSize(width: 340, height: 200)

  @Test func blackStartsAtBottomAndBrightensWhenDraggedUp() {
    let black = SpaceHSBColor(rgb: SpaceRGBColor(red: 0, green: 0, blue: 0))
    #expect(black.fieldPosition(in: field).y == field.height)

    let dragged = black.withHue(0.6).movingField(to: CGPoint(x: 340, y: 0), in: field)
    #expect(dragged.brightness == 1)
    #expect(dragged.saturation == 1)
    #expect(dragged.rgb.blue == 255)
    #expect(dragged.rgb.red == 0)
  }

  @Test func hueSurvivesBlackAndGray() {
    let blue = SpaceHSBColor(hue: 0.6, saturation: 0.8, brightness: 0)
    #expect(blue.rgb == SpaceRGBColor(red: 0, green: 0, blue: 0))
    #expect(blue.hue == 0.6)
    let brightened = blue.movingField(to: CGPoint(x: 272, y: 0), in: field)
    #expect(brightened.hue == 0.6)
    #expect(brightened.rgb.blue > brightened.rgb.red)
  }

  @Test func hueSliderChangesTheColor() {
    let red = SpaceHSBColor(hue: 0, saturation: 1, brightness: 1)
    #expect(red.rgb == SpaceRGBColor(red: 255, green: 0, blue: 0))
    #expect(red.withHue(1.0 / 3).rgb == SpaceRGBColor(red: 0, green: 255, blue: 0))
    #expect(red.withHue(2.0 / 3).rgb == SpaceRGBColor(red: 0, green: 0, blue: 255))
  }

  @Test func rgbRoundTripsWithinOneStep() {
    let samples = [
      SpaceRGBColor(red: 168, green: 153, blue: 212), SpaceRGBColor(red: 54, green: 217, blue: 144),
      SpaceRGBColor(red: 255, green: 133, blue: 83), SpaceRGBColor(red: 103, green: 105, blue: 143),
      SpaceRGBColor(red: 128, green: 128, blue: 128),
    ]
    for sample in samples {
      let result = SpaceHSBColor(rgb: sample).rgb
      #expect(abs(Int(result.red) - Int(sample.red)) <= 1)
      #expect(abs(Int(result.green) - Int(sample.green)) <= 1)
      #expect(abs(Int(result.blue) - Int(sample.blue)) <= 1)
    }
  }

  @Test func fieldClampsOutsideDrags() {
    let color = SpaceHSBColor(hue: 0.3, saturation: 0.5, brightness: 0.5)
      .movingField(to: CGPoint(x: -50, y: 900), in: field)
    #expect(color.saturation == 0)
    #expect(color.brightness == 0)
  }

  @Test func iconCatalogIsLargeAndSearchable() {
    let count = SpaceIconCatalog.sections(matching: "").reduce(0) { $0 + $1.symbols.count }
    #expect(count >= 150)
    let leaves = SpaceIconCatalog.sections(matching: "leaf").flatMap(\.symbols)
    #expect(leaves.contains("leaf"))
    #expect(leaves.allSatisfy { $0.contains("leaf") })
  }
}
