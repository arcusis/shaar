// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

/// A leading swatch for subjects whose color is optional, such as profiles.
struct ThemeColorClearOption {
  let isSelected: Bool
  let select: () -> Void
}

/// Color field, hue slider, named swatches and a hex field, shared by the Space and profile
/// editors.
struct ThemeColorPicker: View {
  @Binding var color: ThemeColorDraft
  var clearOption: ThemeColorClearOption?
  var focusOnAppear = false
  @State private var hsb: HSBColor
  @State private var hexDraft: String
  @FocusState private var fieldFocused: Bool

  init(
    color: Binding<ThemeColorDraft>, clearOption: ThemeColorClearOption? = nil,
    focusOnAppear: Bool = false
  ) {
    _color = color
    self.clearOption = clearOption
    self.focusOnAppear = focusOnAppear
    _hsb = State(initialValue: HSBColor(rgb: color.wrappedValue.color))
    _hexDraft = State(initialValue: color.wrappedValue.color.hex)
  }

  var body: some View {
    VStack(spacing: 12) {
      ThemeColorField(hsb: hsb) { update($0) }
        .frame(height: 200)
        .environment(\.layoutDirection, .leftToRight)
        .focusable()
        .focused($fieldFocused)
      ThemeHueSlider(hsb: hsb) { update($0) }
        .frame(height: 28)
        .environment(\.layoutDirection, .leftToRight)
      HStack(spacing: 10) {
        swatches
        hexField
      }
    }
    .onAppear { if focusOnAppear { fieldFocused = true } }
    .onChange(of: color.color) { _, value in syncFromDraft(value) }
  }

  private var isCleared: Bool { clearOption?.isSelected == true }

  private var swatches: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 1) {
        if let clearOption {
          ThemeColorSwatch(
            label: SettingsL10n.string("No color"), selected: clearOption.isSelected,
            action: clearOption.select
          ) { NoColorMark() }
        }
        ForEach(SpaceTint.allCases, id: \.self) { tint in
          swatch(
            name: SettingsL10n.string(tint.rawValue.capitalized),
            rgb: SpaceTintRGB.color(for: tint),
            selected: isPresetSelected(tint)
          ) { color.selectPreset(tint) }
        }
        ForEach(ThemeColorPalette.extras, id: \.name) { item in
          swatch(name: item.name, rgb: item.color, selected: isCustomSelected(item.color)) {
            color.setCustom(item.color)
          }
        }
      }
      .padding(3)
    }
    .mask(trailingFade)
  }

  /// Fades the last swatches so a row wider than its container reads as scrollable.
  private var trailingFade: some View {
    LinearGradient(
      stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
      startPoint: .leading, endPoint: .trailing)
  }

  private var hexField: some View {
    HStack(spacing: 6) {
      Circle().fill(Color(spaceRGB: hsb.rgb)).frame(width: 14, height: 14)
      TextField(SettingsL10n.string("Hex"), text: $hexDraft)
        .environment(\.layoutDirection, .leftToRight)
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .frame(width: 64)
        .onSubmit { commitHex() }
        .accessibilityLabel(SettingsL10n.string("Hex color"))
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(color.canSubmit ? .clear : .red, lineWidth: 1))
  }

  private func isPresetSelected(_ tint: SpaceTint) -> Bool {
    !isCleared && color.tint == tint && color.customRGB == nil
  }

  private func isCustomSelected(_ rgb: SpaceRGBColor) -> Bool {
    !isCleared && color.customRGB == rgb
  }

  private func swatch(
    name: String, rgb: SpaceRGBColor, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    ThemeColorSwatch(
      label: SettingsL10n.format("%@ color", .string(name)), selected: selected, action: action
    ) {
      Circle().fill(Color(spaceRGB: rgb))
    }
  }

  private func update(_ value: HSBColor) {
    hsb = value
    hexDraft = value.rgb.hex
    color.setCustom(value.rgb)
  }

  /// Swatches and hex edits change the color from outside the field; keep the edited hue when
  /// the color already matches what the field wrote.
  private func syncFromDraft(_ value: SpaceRGBColor) {
    guard value != hsb.rgb else { return }
    hsb = HSBColor(rgb: value)
    hexDraft = value.hex
  }

  private func commitHex() {
    if !color.setHexDraft(hexDraft) { hexDraft = color.hexValue }
  }
}

private struct ThemeColorSwatch<Mark: View>: View {
  let label: String
  let selected: Bool
  let action: () -> Void
  @ViewBuilder let mark: () -> Mark

  var body: some View {
    Button(action: action) {
      mark()
        .frame(width: 18, height: 18).padding(3)
        .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct NoColorMark: View {
  var body: some View {
    Circle().strokeBorder(Color.secondary, lineWidth: 1)
      .overlay(Rectangle().fill(Color.secondary).frame(width: 1).rotationEffect(.degrees(45)))
      .clipShape(Circle())
  }
}

/// Saturation left to right, brightness bottom to top, for the current hue.
private struct ThemeColorField: View {
  let hsb: HSBColor
  let onChange: (HSBColor) -> Void

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let handle = hsb.fieldPosition(in: size)
      ZStack(alignment: .topLeading) {
        Color(hue: hsb.hue, saturation: 1, brightness: 1)
        LinearGradient(
          colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
        LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
        dotGrid
        Circle().fill(Color(spaceRGB: hsb.rgb)).frame(width: 26, height: 26)
          .overlay(Circle().strokeBorder(.white, lineWidth: 3))
          .shadow(color: .black.opacity(0.35), radius: 3)
          .position(
            x: min(max(13, handle.x), size.width - 13),
            y: min(max(13, handle.y), size.height - 13))
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { value in
          onChange(hsb.movingField(to: value.location, in: size))
        })
    }
    .accessibilityElement()
    .accessibilityLabel(SettingsL10n.string("Theme color field"))
    .accessibilityValue(
      SettingsL10n.format(
        "Saturation %d percent, brightness %d percent",
        .integer(Int(hsb.saturation * 100)), .integer(Int(hsb.brightness * 100)))
    )
    .accessibilityAdjustableAction { direction in
      let delta = direction == .increment ? 0.05 : -0.05
      onChange(
        HSBColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness + delta))
    }
  }

  private var dotGrid: some View {
    Canvas { context, size in
      for x in stride(from: 5.0, through: size.width, by: 7) {
        for y in stride(from: 5.0, through: size.height, by: 7) {
          context.fill(
            Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
            with: .color(.white.opacity(0.18)))
        }
      }
    }
    .allowsHitTesting(false)
  }
}

/// Rainbow track with a large pill thumb, as in Arc's theme picker.
private struct ThemeHueSlider: View {
  let hsb: HSBColor
  let onChange: (HSBColor) -> Void
  private let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
    Color(hue: $0, saturation: 1, brightness: 1)
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(LinearGradient(colors: hues, startPoint: .leading, endPoint: .trailing))
          .frame(height: 12)
        Capsule().fill(Color(hue: hsb.hue, saturation: 1, brightness: 1))
          .frame(width: 18, height: 28)
          .overlay(Capsule().strokeBorder(.white, lineWidth: 3))
          .shadow(color: .black.opacity(0.35), radius: 3)
          .offset(x: min(max(0, hsb.hue * width - 9), width - 18))
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { value in
          guard width > 0 else { return }
          onChange(hsb.withHue(value.location.x / width))
        })
    }
    .accessibilityElement()
    .accessibilityLabel(SettingsL10n.string("Theme hue"))
    .accessibilityValue(SettingsL10n.format("%d degrees", .integer(Int(hsb.hue * 360))))
    .accessibilityAdjustableAction { direction in
      onChange(hsb.withHue(hsb.hue + (direction == .increment ? 0.02 : -0.02)))
    }
  }
}

extension Color {
  init(spaceRGB color: SpaceRGBColor) {
    self.init(
      .sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
      blue: Double(color.blue) / 255)
  }
}
