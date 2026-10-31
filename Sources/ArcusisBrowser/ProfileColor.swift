// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

/// A profile's optional color: none, a preset tint, or a custom color.
struct ProfileColorChoice: Equatable {
  var tint: SpaceTint?
  var customRGB: SpaceRGBColor?

  static let none = ProfileColorChoice()

  init(tint: SpaceTint? = nil, customRGB: SpaceRGBColor? = nil) {
    self.tint = tint
    self.customRGB = customRGB
  }

  init(profile: BrowserProfile) {
    self.init(tint: profile.tint, customRGB: profile.customRGB)
  }

  /// A custom color wins over the preset, matching how Spaces resolve their theme.
  var rgb: SpaceRGBColor? {
    if let customRGB { return customRGB }
    return tint.map(SpaceTintRGB.color(for:))
  }
}

/// The profile's person glyph, filled with its color when it has one.
struct ProfileBadge: View {
  let color: SpaceRGBColor?
  var size: CGFloat = 22

  var body: some View {
    if let color {
      Image(systemName: "person.fill")
        .font(.system(size: size * 0.5, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(spaceRGB: color), in: Circle())
    } else {
      Image(systemName: "person.crop.circle")
        .font(.system(size: size * 0.85))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
    }
  }
}

/// Swatches for no color, the preset tints and the named palette, plus a custom color well.
struct ProfileColorPicker: View {
  @Binding var color: ProfileColorChoice
  /// Fixed columns keep the picker narrow enough for the Settings detail column.
  private let columns = Array(repeating: GridItem(.fixed(24), spacing: 4), count: 8)

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
        noColorSwatch
        ForEach(SpaceTint.allCases, id: \.self) { tint in
          swatch(
            name: tint.rawValue.capitalized, rgb: SpaceTintRGB.color(for: tint),
            choice: ProfileColorChoice(tint: tint))
        }
        ForEach(SpaceColorPalette.extras, id: \.name) { item in
          swatch(
            name: item.name, rgb: item.color, choice: ProfileColorChoice(customRGB: item.color))
        }
      }
      HStack(spacing: 8) {
        Text("Custom color").foregroundStyle(.secondary)
        ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
          .labelsHidden()
          .frame(width: 44, height: 22)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Profile color")
  }

  private var noColorSwatch: some View {
    let mark = Circle().strokeBorder(Color.secondary, lineWidth: 1)
      .overlay(Rectangle().fill(Color.secondary).frame(width: 1).rotationEffect(.degrees(45)))
      .clipShape(Circle())
    return selectableSwatch(name: "No color", mark: mark, selected: color == .none) {
      color = .none
    }
  }

  private func swatch(name: String, rgb: SpaceRGBColor, choice: ProfileColorChoice) -> some View {
    let mark = Circle().fill(Color(spaceRGB: rgb))
    return selectableSwatch(name: name, mark: mark, selected: color == choice) { color = choice }
  }

  private func selectableSwatch<Mark: View>(
    name: String, mark: Mark, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      mark
        .frame(width: 18, height: 18)
        .padding(3)
        .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var customColor: Binding<Color> {
    Binding(
      get: { color.rgb.map(Color.init(spaceRGB:)) ?? .gray },
      set: { value in
        if let rgb = SpaceRGBColor(color: value) { color = ProfileColorChoice(customRGB: rgb) }
      })
  }
}

extension SpaceRGBColor {
  init?(color: Color) {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    let channel = { (value: CGFloat) in UInt8((min(1, max(0, value)) * 255).rounded()) }
    self.init(
      red: channel(srgb.redComponent), green: channel(srgb.greenComponent),
      blue: channel(srgb.blueComponent))
  }
}
