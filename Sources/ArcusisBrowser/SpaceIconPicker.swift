import AppKit
import SwiftUI

struct SpaceIconPicker: View {
  @Binding var symbol: String
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search icons", text: $query)
          .textFieldStyle(.plain)
          .accessibilityLabel("Search icons")
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(SpaceIconCatalog.sections(matching: query), id: \.name) { section in
            Text(section.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
              ForEach(section.symbols, id: \.self) { value in iconButton(value) }
            }
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(14)
    .frame(width: 330, height: 380)
  }

  private func iconButton(_ value: String) -> some View {
    Button {
      symbol = value
      dismiss()
    } label: {
      Image(systemName: value)
        .font(.system(size: 15))
        .frame(width: 34, height: 34)
        .background(
          symbol == value ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04),
          in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .help(value)
    .accessibilityLabel(value)
  }
}

/// SF Symbols offered for Spaces, grouped like a small emoji picker.
enum SpaceIconCatalog {
  struct Section {
    let name: String
    let symbols: [String]
  }

  static let all: [Section] = [
    Section(name: "General", symbols: [
      "house", "house.fill", "star", "star.fill", "heart", "heart.fill", "bolt", "bolt.fill",
      "flame", "flame.fill", "sparkles", "crown", "crown.fill", "flag", "flag.fill", "bookmark",
      "bookmark.fill", "tag", "tag.fill", "bell", "bell.fill", "pin", "pin.fill", "lightbulb",
      "lightbulb.fill", "target", "scope", "infinity", "seal", "checkmark.seal.fill",
    ]),
    Section(name: "Work", symbols: [
      "briefcase", "briefcase.fill", "building.2", "building.2.fill", "building.columns",
      "chart.bar", "chart.bar.fill", "chart.pie", "chart.line.uptrend.xyaxis", "doc", "doc.fill",
      "doc.text", "folder", "folder.fill", "tray", "tray.full", "archivebox", "calendar",
      "clock", "list.bullet", "checklist", "square.and.pencil", "pencil", "paperclip",
      "signature", "dollarsign.circle", "creditcard", "banknote", "cart", "bag",
    ]),
    Section(name: "Tech", symbols: [
      "laptopcomputer", "desktopcomputer", "iphone", "server.rack", "cpu", "memorychip",
      "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "hammer",
      "wrench.and.screwdriver", "gearshape", "gearshape.2", "cube", "shippingbox", "network",
      "antenna.radiowaves.left.and.right", "wifi", "lock", "lock.shield", "key", "shield",
      "externaldrive", "icloud", "cloud", "cloud.fill", "bolt.horizontal", "puzzlepiece",
      "atom", "testtube.2",
    ]),
    Section(name: "Communication", symbols: [
      "envelope", "envelope.fill", "paperplane", "paperplane.fill", "bubble.left",
      "bubble.left.and.bubble.right", "phone", "video", "megaphone", "mic", "quote.bubble",
      "person", "person.fill", "person.2", "person.2.fill", "person.3", "person.crop.circle",
      "hand.wave", "hand.thumbsup", "at", "link", "globe", "newspaper", "book", "book.fill",
      "books.vertical", "graduationcap", "studentdesk", "text.book.closed", "character.book.closed",
    ]),
    Section(name: "Life", symbols: [
      "cup.and.saucer", "fork.knife", "takeoutbag.and.cup.and.straw", "birthday.cake",
      "gift", "party.popper", "music.note", "headphones", "guitars", "film", "tv", "gamecontroller",
      "camera", "photo", "paintpalette", "paintbrush", "theatermasks", "figure.run",
      "dumbbell", "sportscourt", "soccerball", "basketball", "bicycle", "heart.text.square",
      "cross.case", "pills", "stethoscope", "pawprint", "dog", "cat",
    ]),
    Section(name: "Nature and travel", symbols: [
      "leaf", "leaf.fill", "tree", "camera.macro", "sun.max", "moon", "moon.stars", "cloud.sun",
      "snowflake", "drop", "flame.circle", "mountain.2", "globe.americas", "globe.europe.africa",
      "airplane", "car", "bus", "tram", "ferry", "sailboat", "map", "mappin.and.ellipse",
      "location", "signpost.right", "tent", "beach.umbrella", "binoculars", "suitcase",
      "fuelpump", "house.lodge",
    ]),
    Section(name: "Shapes", symbols: [
      "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill", "diamond",
      "diamond.fill", "hexagon", "hexagon.fill", "octagon", "seal.fill", "capsule", "rhombus",
      "square.stack", "square.stack.3d.up", "square.grid.2x2", "circle.grid.3x3", "rectangle.3.group",
      "app", "app.fill", "staroflife", "asterisk", "number", "plus.circle", "smallcircle.filled.circle",
      "circle.hexagongrid", "sparkle", "rays", "wand.and.stars",
    ]),
  ]

  static func sections(matching query: String) -> [Section] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    return all.compactMap { section in
      let symbols = section.symbols.filter { symbol in
        isAvailable(symbol) && (needle.isEmpty || symbol.contains(needle))
      }
      return symbols.isEmpty ? nil : Section(name: section.name, symbols: symbols)
    }
  }

  private static func isAvailable(_ symbol: String) -> Bool {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
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
