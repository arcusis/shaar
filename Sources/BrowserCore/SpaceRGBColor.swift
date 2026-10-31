// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Opaque sRGB color stored without floating-point rounding.
public struct SpaceRGBColor: Codable, Equatable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public init?(hex: String) {
    let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard value.count == 6,
      value.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (65...70).contains($0.value)
          || (97...102).contains($0.value)
      }),
      let number = UInt32(value, radix: 16)
    else { return nil }
    self.init(
      red: UInt8((number >> 16) & 0xFF), green: UInt8((number >> 8) & 0xFF),
      blue: UInt8(number & 0xFF))
  }

  public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

  private enum CodingKeys: String, CodingKey { case red, green, blue }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    red = try values.decode(UInt8.self, forKey: .red)
    green = try values.decode(UInt8.self, forKey: .green)
    blue = try values.decode(UInt8.self, forKey: .blue)
  }
}
