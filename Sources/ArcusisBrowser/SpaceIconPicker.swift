import AppKit
import SwiftUI

struct SpaceIconPicker: View {
  @Binding var symbol: String
  @Environment(\.dismiss) private var dismiss
  private let symbols = [
    "house", "star.fill", "briefcase", "globe", "folder", "heart.fill", "leaf.fill", "airplane",
    "cloud", "book.fill", "graduationcap.fill", "paintpalette.fill", "gamecontroller.fill",
    "music.note", "camera.fill", "square.stack",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Change Space Icon").font(.headline)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 4), spacing: 6) {
        ForEach(symbols, id: \.self) { value in
          Button {
            symbol = value
            dismiss()
          } label: {
            Image(systemName: value).frame(width: 36, height: 36)
              .background(
                symbol == value ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
          }.buttonStyle(.plain).accessibilityLabel(value)
        }
      }

    }.padding(16).frame(width: 200)
  }
}

struct SpaceIcon: View {
  let symbol: String
  var body: some View {
    if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
      Image(systemName: symbol)
    } else {
      Text(symbol)
    }
  }
}
