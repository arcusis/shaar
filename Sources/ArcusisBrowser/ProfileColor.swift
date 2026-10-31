// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

  /// The picker always edits a concrete color, so an uncolored profile starts from the first
  /// preset.
  var draft: ThemeColorDraft {
    ThemeColorDraft(tint: tint ?? .lavender, customRGB: customRGB)
  }

  /// Takes the picker's color unless its hex text does not parse; the field then returns to the
  /// profile's current color.
  mutating func apply(_ draft: ThemeColorDraft) {
    guard draft.canSubmit else { return }
    self = ProfileColorChoice(tint: draft.tint, customRGB: draft.customRGB)
  }
}

extension BrowserProfile {
  static let defaultSymbol = "person.fill"

  var displaySymbol: String { symbol ?? Self.defaultSymbol }
}

/// The profile's symbol, white on its color, or muted when it has no color.
struct ProfileBadge: View {
  let color: SpaceRGBColor?
  var symbol = BrowserProfile.defaultSymbol
  var size: CGFloat = 22

  var body: some View {
    if let color {
      glyph
        .foregroundStyle(.white)
        .background(Color(spaceRGB: color), in: Circle())
    } else {
      glyph
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.08), in: Circle())
    }
  }

  private var glyph: some View {
    SymbolImage(symbol: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .frame(width: size, height: size)
  }
}

/// The Space theme picker with a leading No color swatch, since a profile's color is optional.
struct ProfileColorPicker: View {
  @Binding var color: ProfileColorChoice

  var body: some View {
    ThemeColorPicker(
      color: draft,
      clearOption: ThemeColorClearOption(isSelected: color == .none) { color = .none }
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Profile color")
  }

  private var draft: Binding<ThemeColorDraft> {
    Binding(get: { color.draft }, set: { color.apply($0) })
  }
}
