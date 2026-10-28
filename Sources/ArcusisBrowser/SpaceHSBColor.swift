import BrowserCore
import CoreGraphics

/// Hue, saturation and brightness kept separately while editing, so dark or gray colors keep
/// the hue the user chose instead of collapsing to red.
struct SpaceHSBColor: Equatable {
  private(set) var hue: Double
  private(set) var saturation: Double
  private(set) var brightness: Double

  init(hue: Double, saturation: Double, brightness: Double) {
    self.hue = Self.unit(hue)
    self.saturation = Self.unit(saturation)
    self.brightness = Self.unit(brightness)
  }

  init(rgb: SpaceRGBColor) {
    let red = Double(rgb.red) / 255
    let green = Double(rgb.green) / 255
    let blue = Double(rgb.blue) / 255
    let maximum = max(red, green, blue)
    let delta = maximum - min(red, green, blue)
    self.init(
      hue: Self.hue(red: red, green: green, blue: blue, maximum: maximum, delta: delta),
      saturation: maximum == 0 ? 0 : delta / maximum,
      brightness: maximum)
  }

  var rgb: SpaceRGBColor {
    let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
    let chroma = brightness * saturation
    let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let (red, green, blue) = Self.channels(sector: Int(sector), chroma: chroma, second: second)
    let offset = brightness - chroma
    return SpaceRGBColor(
      red: Self.byte(red + offset), green: Self.byte(green + offset), blue: Self.byte(blue + offset))
  }

  /// Color field: saturation runs left to right, brightness bottom to top.
  func fieldPosition(in size: CGSize) -> CGPoint {
    CGPoint(x: saturation * size.width, y: (1 - brightness) * size.height)
  }

  func movingField(to point: CGPoint, in size: CGSize) -> Self {
    guard size.width > 0, size.height > 0 else { return self }
    return Self(hue: hue, saturation: point.x / size.width, brightness: 1 - point.y / size.height)
  }

  func withHue(_ value: Double) -> Self {
    Self(hue: value, saturation: saturation, brightness: brightness)
  }

  private static func unit(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
  }

  private static func byte(_ value: Double) -> UInt8 {
    UInt8((unit(value) * 255).rounded())
  }

  private static func hue(
    red: Double, green: Double, blue: Double, maximum: Double, delta: Double
  ) -> Double {
    guard delta > 0 else { return 0 }
    let sector: Double
    if maximum == red {
      sector = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
    } else if maximum == green {
      sector = (blue - red) / delta + 2
    } else {
      sector = (red - green) / delta + 4
    }
    let hue = sector / 6
    return hue < 0 ? hue + 1 : hue
  }

  private static func channels(sector: Int, chroma: Double, second: Double) -> (
    Double, Double, Double
  ) {
    switch sector {
    case 0: (chroma, second, 0)
    case 1: (second, chroma, 0)
    case 2: (0, chroma, second)
    case 3: (0, second, chroma)
    case 4: (second, 0, chroma)
    default: (chroma, 0, second)
    }
  }
}
