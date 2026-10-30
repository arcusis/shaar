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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
              ForEach(section.symbols, id: \.self) { value in iconButton(value) }
            }
          }
        }
        .padding(.vertical, 2)
        // Keeps the last column clear of the overlay scroll bar.
        .padding(.trailing, 12)
      }
    }
    .padding(14)
    .frame(width: 330, height: 380)
    .background(Color(nsColor: .windowBackgroundColor))
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
          in: RoundedRectangle(cornerRadius: 8)
        )
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

  static let all: [Section] = {
    let sections: [Section] = [
      Section(
        name: "General",
        symbols: [
          "house", "house.fill", "star", "star.fill", "heart", "heart.fill", "bolt", "bolt.fill",
          "flame", "flame.fill", "sparkles", "crown", "crown.fill", "flag", "flag.fill", "bookmark",
          "bookmark.fill", "tag", "tag.fill", "bell", "bell.fill", "pin", "pin.fill", "lightbulb",
          "lightbulb.fill", "target", "scope", "infinity", "seal", "checkmark.seal.fill",
        ]),
      Section(
        name: "Work",
        symbols: [
          "briefcase", "briefcase.fill", "building.2", "building.2.fill", "building.columns",
          "chart.bar", "chart.bar.fill", "chart.pie", "chart.line.uptrend.xyaxis", "doc",
          "doc.fill", "doc.text", "folder", "folder.fill", "tray", "tray.full", "archivebox",
          "calendar", "clock", "list.bullet", "checklist", "square.and.pencil", "pencil",
          "paperclip", "signature", "person.crop.rectangle", "clipboard", "printer", "paperclip",
          "chart.xyaxis.line",
        ]),
      Section(
        name: "Communication",
        symbols: [
          "envelope", "envelope.fill", "paperplane", "paperplane.fill", "bubble.left",
          "bubble.left.and.bubble.right", "phone", "video", "megaphone", "mic", "quote.bubble",
          "person", "person.fill", "person.2", "person.2.fill", "person.3", "person.crop.circle",
          "hand.wave", "hand.thumbsup", "at", "link", "globe", "message", "message.fill",
          "phone.fill", "video.fill", "captions.bubble", "bubble.right", "bubble.middle.bottom",
          "person.crop.circle.badge.checkmark",
        ]),
      Section(
        name: "Travel",
        symbols: [
          "airplane", "airplane.departure", "airplane.arrival", "car", "car.fill", "bus", "tram",
          "ferry", "sailboat", "map", "mappin.and.ellipse", "location", "signpost.right", "tent",
          "beach.umbrella", "binoculars", "suitcase", "fuelpump", "house.lodge", "bicycle",
          "train.side.front.car", "steeringwheel", "globe.americas", "globe.europe.africa",
          "location.north", "map.fill", "ticket", "figure.hiking",
        ]),
      Section(
        name: "Food",
        symbols: [
          "cup.and.saucer", "fork.knife", "takeoutbag.and.cup.and.straw", "birthday.cake", "carrot",
          "fish", "leaf", "wineglass", "mug", "waterbottle", "refrigerator", "oven",
          "birthday.cake.fill", "basket", "takeoutbag.and.cup.and.straw.fill", "fork.knife.circle",
          "carrot.fill", "fish.fill", "cup.and.saucer.fill", "popcorn", "birthday.cake",
          "frying.pan", "sink", "table.furniture", "stove", "waterbottle.fill", "wineglass.fill",
          "birthday.cake",
        ]),
      Section(
        name: "Nature",
        symbols: [
          "leaf", "leaf.fill", "tree", "camera.macro", "sun.max", "moon", "moon.stars", "cloud.sun",
          "snowflake", "drop", "flame.circle", "mountain.2", "pawprint", "dog", "cat", "bird",
          "fish", "tortoise", "hare", "ant", "ladybug", "tree.fill", "sun.max.fill", "cloud.rain",
          "cloud.snow", "wind", "thermometer.sun", "rainbow", "water.waves", "globe",
        ]),
      Section(
        name: "Money",
        symbols: [
          "dollarsign.circle", "dollarsign.square", "banknote", "creditcard", "creditcard.fill",
          "cart", "bag", "bag.fill", "wallet.pass", "sterlingsign.circle", "eurosign.circle",
          "yensign.circle", "bitcoinsign.circle", "chart.bar.xaxis", "chart.pie.fill",
          "chart.line.uptrend.xyaxis", "percent", "creditcard.and.123", "giftcard",
          "cart.fill", "basket.fill", "dollarsign", "indianrupeesign.circle", "wonsign.circle",
          "centsign.circle", "coloncurrencysign.circle", "turkishlirasign.circle",
          "australsign.circle", "francsign.circle",
        ]),
      Section(
        name: "Health",
        symbols: [
          "heart.text.square", "cross.case", "pills", "stethoscope", "bandage",
          "medical.thermometer", "syringe", "cross", "cross.fill", "lungs", "brain.head.profile",
          "allergens", "facemask", "ivfluid.bag", "heart", "figure.walk",
          "figure.mind.and.body", "bed.double", "bed.double.fill", "pill", "cross.vial",
          "cross.circle", "cross.case.fill", "medical.thermometer.fill", "waveform.path.ecg",
          "eye", "ear", "lungs.fill",
        ]),
      Section(
        name: "Sports",
        symbols: [
          "figure.run", "dumbbell", "sportscourt", "soccerball", "basketball", "volleyball",
          "tennisball", "football", "baseball", "hockey.puck", "figure.basketball", "figure.soccer",
          "figure.pool.swim", "figure.tennis", "figure.gymnastics", "figure.boxing",
          "figure.skiing.downhill", "figure.snowboarding", "figure.rugby", "figure.cricket",
          "figure.yoga", "figure.cooldown", "figure.strengthtraining.traditional", "figure.walk",
          "figure.bowling", "figure.fencing", "figure.handball", "figure.waterpolo",
          "figure.track.and.field", "medal",
        ]),
      Section(
        name: "Devices",
        symbols: [
          "laptopcomputer", "desktopcomputer", "iphone", "ipad", "applewatch", "server.rack", "cpu",
          "memorychip", "terminal", "curlybraces", "gearshape", "gearshape.2", "cube", "network",
          "wifi", "lock", "lock.shield", "key", "shield", "externaldrive", "icloud", "cloud",
          "cloud.fill", "keyboard", "computermouse", "printer", "display", "macbook", "airpods",
          "headphones",
        ]),
      Section(
        name: "Media",
        symbols: [
          "music.note", "headphones", "guitars", "film", "tv", "gamecontroller", "camera", "photo",
          "paintpalette", "paintbrush", "theatermasks", "play", "play.fill", "pause",
          "record.circle", "music.mic", "radio", "speaker.wave.2", "movieclapper",
          "photo.stack", "camera.fill", "video", "waveform", "metronome", "pianokeys",
          "music.note.list", "airplayvideo", "music.quarternote.3", "mic.fill",
        ]),
      Section(
        name: "Education",
        symbols: [
          "book", "book.fill", "books.vertical", "graduationcap", "studentdesk", "text.book.closed",
          "character.book.closed", "pencil", "ruler", "backpack", "globe", "textformat", "abc",
          "function", "sum", "atom", "testtube.2", "book.closed", "book.closed.fill", "bookmark",
          "doc.text", "highlighter", "scribble.variable", "paperclip", "magazine",
          "books.vertical.fill", "ruler.fill", "compass.drawing", "pencil.tip",
        ]),
      Section(
        name: "Home",
        symbols: [
          "house", "house.fill", "door.left.hand.closed", "sofa", "chair.lounge", "bed.double",
          "lamp.desk", "lightbulb", "washer", "dryer", "dishwasher", "refrigerator", "oven",
          "shower", "toilet", "sink", "fireplace", "house.and.flag", "house.lodge",
          "table.furniture", "cabinet", "fan", "door.garage.closed", "key.horizontal",
          "door.left.hand.open", "lamp.floor", "stairs",
        ]),
      Section(
        name: "Symbols",
        symbols: [
          "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill", "diamond",
          "diamond.fill", "hexagon", "hexagon.fill", "octagon", "seal.fill", "capsule", "rhombus",
          "square.stack", "square.stack.3d.up", "square.grid.2x2", "circle.grid.3x3",
          "rectangle.3.group", "app", "app.fill", "staroflife", "asterisk", "number", "plus.circle",
          "smallcircle.filled.circle", "circle.hexagongrid", "sparkle", "rays", "wand.and.stars",
        ]),
    ]
    var seen = Set<String>()
    return sections.map { section in
      Section(name: section.name, symbols: section.symbols.filter { seen.insert($0).inserted })
    }
  }()

  private static let keywords: [String: String] = [
    "airplane": "plane flight travel", "airplane.departure": "plane flight takeoff",
    "airplane.arrival": "plane flight landing", "dollarsign.circle": "money cash finance",
    "dollarsign.square": "money cash finance", "banknote": "money cash bill",
    "creditcard": "money payment finance", "creditcard.fill": "money payment finance",
    "terminal": "code programming developer", "curlybraces": "code programming developer",
    "chevron.left.forwardslash.chevron.right": "code programming developer",
    "laptopcomputer": "computer code work", "graduationcap": "education school learning",
    "fork.knife": "food meal restaurant", "cup.and.saucer": "food coffee tea",
    "figure.run": "sports exercise fitness", "heart.text.square": "health medical",
    "paperplane": "send message flight", "car": "travel vehicle drive",
  ]

  static func sections(matching query: String) -> [Section] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    return all.compactMap { section in
      let sectionMatches = needle.isEmpty || section.name.lowercased().contains(needle)
      let symbols = section.symbols.filter { symbol in
        isAvailable(symbol) && (sectionMatches || searchText(for: symbol).contains(needle))
      }
      return symbols.isEmpty ? nil : Section(name: section.name, symbols: symbols)
    }
  }

  private static func searchText(for symbol: String) -> String {
    "\(symbol) \(keywords[symbol, default: ""])".lowercased()
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
