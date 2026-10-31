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

struct SpaceAppearanceDraft: Equatable {
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

enum SpaceEditorSavePolicy {
  static func isDisabled(name: String, appearance: SpaceAppearanceDraft) -> Bool {
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

/// Named colors offered next to the preset tints wherever a Space or profile color is picked.
enum SpaceColorPalette {
  static let extras: [(name: String, color: SpaceRGBColor)] = [
    ("White", .init(red: 240, green: 234, blue: 228)),
    ("Pink", .init(red: 237, green: 152, blue: 180)),
    ("Purple", .init(red: 166, green: 112, blue: 160)),
    ("Red", .init(red: 238, green: 83, blue: 100)),
    ("Orange", .init(red: 255, green: 133, blue: 83)),
    ("Yellow", .init(red: 255, green: 215, blue: 90)),
    ("Green", .init(red: 54, green: 217, blue: 144)),
    ("Blue", .init(red: 109, green: 188, blue: 215)),
    ("Slate", .init(red: 103, green: 105, blue: 143)),
  ]
}
