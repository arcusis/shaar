import AppKit
import BrowserCore
import SwiftUI

struct SpaceThemePicker: View {
  @Binding var appearance: SpaceAppearanceDraft
  @Environment(\.colorScheme) private var colorScheme
  @State private var preview: Preview = .automatic
  @FocusState private var canvasFocused: Bool
  var focusOnAppear = false

  private enum Preview: String, CaseIterable {
    case automatic, light, dark
    var symbol: String {
      switch self {
      case .automatic: "sparkles"
      case .light: "sun.max.fill"
      case .dark: "moon.fill"
      }
    }
  }

  private let extraColors: [(String, SpaceRGBColor)] = [
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

  private var nsColor: NSColor {
    let c = appearance.color
    return NSColor(
      srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
      blue: CGFloat(c.blue) / 255, alpha: 1)
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 4) {
        ForEach(Preview.allCases, id: \.self) { mode in
          Button {
            preview = mode
          } label: {
            Image(systemName: mode.symbol)
              .frame(width: 32, height: 28)
              .background(
                preview == mode ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(mode.rawValue.capitalized) appearance preview")
          .accessibilityAddTraits(preview == mode ? .isSelected : [])
        }
      }
      GeometryReader { geometry in
        let color = Color(nsColor: nsColor)
        let x = CGFloat(nsColor.hueComponent) * geometry.size.width
        let y = (1 - CGFloat(nsColor.saturationComponent)) * geometry.size.height
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 12)
            .fill(
              LinearGradient(
                colors: [
                  color.opacity(0.85), color.opacity(0.35),
                  (preview == .light || (preview == .automatic && colorScheme == .light))
                    ? .white.opacity(0.65) : .black.opacity(0.35),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing))
          Canvas { context, size in
            for x in stride(from: 5.0, through: size.width, by: 6) {
              for y in stride(from: 5.0, through: size.height, by: 6) {
                context.fill(
                  Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                  with: .color(.white.opacity(0.28)))
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 12))
          Circle().fill(color).frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(radius: 3)
            .position(
              x: min(max(12, x), geometry.size.width - 12),
              y: min(max(12, y), geometry.size.height - 12))
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            let hue = min(1, max(0, value.location.x / geometry.size.width))
            let saturation = 1 - min(1, max(0, value.location.y / geometry.size.height))
            setColor(
              NSColor(
                hue: hue, saturation: saturation, brightness: nsColor.brightnessComponent, alpha: 1)
            )
          })
      }
      .frame(height: 200)
      .focusable()
      .focused($canvasFocused)
      .accessibilityLabel("Theme color field")
      .accessibilityValue(
        "Hue \(Int(nsColor.hueComponent * 360)) degrees, saturation \(Int(nsColor.saturationComponent * 100)) percent"
      )
      .accessibilityAdjustableAction { direction in
        let delta: CGFloat = direction == .increment ? 0.02 : -0.02
        setColor(
          NSColor(
            hue: min(1, max(0, nsColor.hueComponent + delta)),
            saturation: nsColor.saturationComponent, brightness: nsColor.brightnessComponent,
            alpha: 1))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 1) {
          ForEach(SpaceTint.allCases, id: \.self) { tint in
            swatch(
              name: tint.rawValue.capitalized,
              color: SpaceAppearanceDraft(tint: tint, customRGB: nil).color,
              selected: appearance.tint == tint && appearance.customRGB == nil
            ) { appearance.selectPreset(tint) }
          }
          ForEach(extraColors, id: \.0) { item in
            swatch(name: item.0, color: item.1, selected: appearance.customRGB == item.1) {
              appearance.setCustom(item.1)
            }
          }
        }.padding(3)
      }
      HStack {
        Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { Double(nsColor.brightnessComponent) },
            set: { value in
              setColor(
                NSColor(
                  hue: nsColor.hueComponent, saturation: nsColor.saturationComponent,
                  brightness: value, alpha: 1))
            }), in: 0...1
        )
        .accessibilityLabel("Theme intensity")
      }
    }
    .onAppear { if focusOnAppear { canvasFocused = true } }
  }

  private func swatch(
    name: String, color: SpaceRGBColor, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Circle().fill(
        Color(
          .sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
          blue: Double(color.blue) / 255)
      )
      .frame(width: 18, height: 18).padding(3)
      .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
    }.buttonStyle(.plain).accessibilityLabel("\(name) sidebar color")
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func setColor(_ color: NSColor) {
    guard let rgb = color.usingColorSpace(.sRGB) else {
      appearance.rejectColorInput()
      return
    }
    _ = appearance.setCustomComponents(
      red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
  }
}
