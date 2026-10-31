import BrowserCore
import SwiftUI

struct SpaceThemePicker: View {
  @Binding var appearance: SpaceAppearanceDraft
  var focusOnAppear = false
  @State private var hsb: SpaceHSBColor
  @State private var hexDraft: String
  @FocusState private var fieldFocused: Bool

  init(appearance: Binding<SpaceAppearanceDraft>, focusOnAppear: Bool = false) {
    _appearance = appearance
    self.focusOnAppear = focusOnAppear
    _hsb = State(initialValue: SpaceHSBColor(rgb: appearance.wrappedValue.color))
    _hexDraft = State(initialValue: appearance.wrappedValue.color.hex)
  }

  var body: some View {
    VStack(spacing: 12) {
      SpaceColorField(hsb: hsb) { update($0) }
        .frame(height: 200)
        .focusable()
        .focused($fieldFocused)
      SpaceHueSlider(hsb: hsb) { update($0) }
        .frame(height: 28)
      HStack(spacing: 10) {
        swatches
        hexField
      }
    }
    .onAppear { if focusOnAppear { fieldFocused = true } }
    .onChange(of: appearance.color) { _, color in syncFromAppearance(color) }
  }

  private var swatches: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 1) {
        ForEach(SpaceTint.allCases, id: \.self) { tint in
          swatch(
            name: tint.rawValue.capitalized,
            color: SpaceAppearanceDraft(tint: tint, customRGB: nil).color,
            selected: appearance.tint == tint && appearance.customRGB == nil
          ) { appearance.selectPreset(tint) }
        }
        ForEach(SpaceColorPalette.extras, id: \.name) { item in
          swatch(name: item.name, color: item.color, selected: appearance.customRGB == item.color) {
            appearance.setCustom(item.color)
          }
        }
      }
      .padding(3)
    }
  }

  private var hexField: some View {
    HStack(spacing: 6) {
      Circle().fill(Color(spaceRGB: hsb.rgb)).frame(width: 14, height: 14)
      TextField("Hex", text: $hexDraft)
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .frame(width: 64)
        .onSubmit { commitHex() }
        .accessibilityLabel("Hex color")
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(appearance.canSubmit ? .clear : .red, lineWidth: 1))
  }

  private func swatch(
    name: String, color: SpaceRGBColor, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Circle().fill(Color(spaceRGB: color))
        .frame(width: 18, height: 18).padding(3)
        .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name) sidebar color")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func update(_ value: SpaceHSBColor) {
    hsb = value
    hexDraft = value.rgb.hex
    appearance.setCustom(value.rgb)
  }

  /// Swatches and hex edits change the color from outside the field; keep the edited hue when
  /// the color already matches what the field wrote.
  private func syncFromAppearance(_ color: SpaceRGBColor) {
    guard color != hsb.rgb else { return }
    hsb = SpaceHSBColor(rgb: color)
    hexDraft = color.hex
  }

  private func commitHex() {
    if !appearance.setHexDraft(hexDraft) { hexDraft = appearance.hexValue }
  }
}

/// Saturation left to right, brightness bottom to top, for the current hue.
private struct SpaceColorField: View {
  let hsb: SpaceHSBColor
  let onChange: (SpaceHSBColor) -> Void

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
    .accessibilityLabel("Theme color field")
    .accessibilityValue(
      "Saturation \(Int(hsb.saturation * 100)) percent, brightness \(Int(hsb.brightness * 100)) percent"
    )
    .accessibilityAdjustableAction { direction in
      let delta = direction == .increment ? 0.05 : -0.05
      onChange(
        SpaceHSBColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness + delta))
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
private struct SpaceHueSlider: View {
  let hsb: SpaceHSBColor
  let onChange: (SpaceHSBColor) -> Void
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
    .accessibilityLabel("Theme hue")
    .accessibilityValue("\(Int(hsb.hue * 360)) degrees")
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
