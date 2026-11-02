// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI

struct InspectorColor: Codable, Equatable, Sendable {
  let css: String
  let rgba: [Double]
  var valid: Bool {
    css.count <= 256 && rgba.count == 4 && rgba.allSatisfy { $0.isFinite && (0...1).contains($0) }
  }
  var color: Color {
    guard valid else { return .clear }
    return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
  }
  enum Format: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case oklch = "OKLCH"
  }
  func formatted(_ format: Format) -> String {
    guard valid else { return css }
    switch format {
    case .hex:
      let channels = rgba.map { Int(($0 * 255).rounded()) }
      return "#" + channels.prefix(rgba[3] < 1 ? 4 : 3).map { String(format: "%02X", $0) }.joined()
    case .rgb:
      let rgb = rgba.prefix(3).map { String(Int(($0 * 255).rounded())) }.joined(separator: " ")
      return "rgb(\(rgb)\(rgba[3] < 1 ? " / \(Self.number(rgba[3], precision: 4))" : ""))"
    case .oklch:
      let c = rgba.prefix(3).map(Self.linear)
      let l = cbrt(0.4122214708 * c[0] + 0.5363325363 * c[1] + 0.0514459929 * c[2])
      let m = cbrt(0.2119034982 * c[0] + 0.6806995451 * c[1] + 0.1073969566 * c[2])
      let s = cbrt(0.0883024619 * c[0] + 0.2817188376 * c[1] + 0.6299787005 * c[2])
      let light = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
      let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
      let b = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
      let chroma = hypot(a, b)
      let hue =
        chroma < 0.00001 ? 0 : (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
      return
        "oklch(\(Self.number(light*100))% \(Self.number(chroma, precision: 4)) \(Self.number(hue))\(rgba[3] < 1 ? " / \(Self.number(rgba[3], precision: 4))" : ""))"
    }
  }
  static func linear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
  static func number(_ value: Double, precision: Int = 2) -> String {
    String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), precision, value)
      .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
  }
  func over(_ background: InspectorColor) -> InspectorColor? {
    guard valid, background.valid else { return nil }
    let alpha = rgba[3] + background.rgba[3] * (1 - rgba[3])
    guard alpha > 0 else { return nil }
    let values = (0..<3).map {
      (rgba[$0] * rgba[3] + background.rgba[$0] * background.rgba[3] * (1 - rgba[3])) / alpha
    }
    return InspectorColor(css: css, rgba: values + [alpha])
  }
  func contrast(on background: InspectorColor) -> Double? {
    guard background.valid, background.rgba[3] == 1, let foreground = over(background) else {
      return nil
    }
    func luminance(_ color: InspectorColor) -> Double {
      let channels = color.rgba.prefix(3).map(Self.linear)
      return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    let first = luminance(foreground)
    let second = luminance(background)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }
}
