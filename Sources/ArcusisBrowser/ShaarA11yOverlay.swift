// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarA11yColor: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

struct ShaarA11yPoint: Equatable {
  var x: Double
  var y: Double
}

struct ShaarFocusStop: Equatable {
  var id: Int
  var tabIndex: Int
  var documentOrder: Int
  var name: String
  var origin: ShaarA11yPoint
}

struct ShaarA11yText: Equatable {
  var id: Int
  var snippet: String
  var origin: ShaarA11yPoint
}

struct ShaarA11yInventory: Equatable {
  var scrollX: Double
  var scrollY: Double
  var stops: [ShaarFocusStop]
  var texts: [ShaarA11yText]
  var truncated: Bool
}

struct ShaarA11yContrastDecision: Equatable {
  var ratio: Double
  var fails: Bool
  var largeText: Bool
}

enum ShaarFocusOrder {
  /// Positive tabindex first, then the natural tab sequence. A negative tabindex is not a stop.
  static func ordered(_ stops: [ShaarFocusStop]) -> [ShaarFocusStop] {
    let eligible = stops.filter { $0.tabIndex >= 0 }
    let positive = eligible.filter { $0.tabIndex > 0 }.sorted(by: earlier)
    let natural = eligible.filter { $0.tabIndex == 0 }.sorted(by: earlier)
    return positive + natural
  }

  private static func earlier(_ lhs: ShaarFocusStop, _ rhs: ShaarFocusStop) -> Bool {
    if lhs.tabIndex != rhs.tabIndex { return lhs.tabIndex < rhs.tabIndex }
    return lhs.documentOrder < rhs.documentOrder
  }
}

enum ShaarA11yContrast {
  static func decide(style: [String: Any]?, colors: [String: Any]?) -> ShaarA11yContrastDecision? {
    guard let colorText = property(style, name: "color"), let foreground = parse(colorText),
      let sizeText = property(style, name: "font-size"), let fontSize = pixels(sizeText),
      let weightText = property(style, name: "font-weight"), let weight = fontWeight(weightText),
      let listed = backgroundColors(colors), !listed.isEmpty
    else { return nil }
    var parsed: [ShaarA11yColor] = []
    for item in listed {
      guard let color = parse(item) else { return nil }
      parsed.append(color)
    }
    guard let background = flatten(topToBottom: parsed), let ratio = ratio(foreground, on: background)
    else { return nil }
    let large = isLargeText(fontSizePx: fontSize, fontWeight: weight)
    return ShaarA11yContrastDecision(
      ratio: ratio, fails: failsAA(ratio: ratio, largeText: large), largeText: large)
  }

  static func ratioText(_ ratio: Double) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), ratio)
  }

  static func parse(_ text: String) -> ShaarA11yColor? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed == "transparent" {
      return ShaarA11yColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
    if trimmed.hasPrefix("#") { return parseHex(trimmed) }
    if trimmed.hasPrefix("rgb") { return parseRGB(trimmed) }
    return nil
  }

  static func failsAA(ratio: Double, largeText: Bool) -> Bool {
    if largeText { return ratio < 3 }
    return ratio < 4.5
  }

  static func isLargeText(fontSizePx: Double, fontWeight: Double) -> Bool {
    if fontSizePx >= 24 { return true }
    return fontSizePx >= 18.5 && fontWeight >= 700
  }

  private static func property(_ style: [String: Any]?, name: String) -> String? {
    guard let style else { return nil }
    for row in ShaarA11yJSON.objects(style["computedStyle"]) where row["name"] as? String == name {
      return row["value"] as? String
    }
    return nil
  }

  private static func backgroundColors(_ colors: [String: Any]?) -> [String]? {
    guard let colors else { return nil }
    let listed = ShaarA11yJSON.strings(colors["backgroundColors"])
    guard !listed.isEmpty else { return nil }
    return listed
  }

  private static func ratio(_ foreground: ShaarA11yColor, on background: ShaarA11yColor)
    -> Double?
  {
    guard background.alpha >= 0.99 else { return nil }
    let painted = over(front: foreground, back: background)
    guard painted.alpha >= 0.99 else { return nil }
    let front = luminance(painted)
    let back = luminance(background)
    return (max(front, back) + 0.05) / (min(front, back) + 0.05)
  }

  private static func flatten(topToBottom colors: [ShaarA11yColor]) -> ShaarA11yColor? {
    guard let bottom = colors.last else { return nil }
    var result = bottom
    for color in colors.dropLast().reversed() {
      result = over(front: color, back: result)
    }
    guard result.alpha >= 0.99 else { return nil }
    return result
  }

  private static func over(front: ShaarA11yColor, back: ShaarA11yColor) -> ShaarA11yColor {
    let alpha = front.alpha + back.alpha * (1 - front.alpha)
    guard alpha > 0 else { return ShaarA11yColor(red: 0, green: 0, blue: 0, alpha: 0) }
    let red = mix(front.red, front.alpha, back.red, back.alpha, alpha)
    let green = mix(front.green, front.alpha, back.green, back.alpha, alpha)
    let blue = mix(front.blue, front.alpha, back.blue, back.alpha, alpha)
    return ShaarA11yColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func mix(
    _ front: Double, _ frontAlpha: Double, _ back: Double, _ backAlpha: Double, _ alpha: Double
  ) -> Double {
    (front * frontAlpha + back * backAlpha * (1 - frontAlpha)) / alpha
  }

  private static func luminance(_ color: ShaarA11yColor) -> Double {
    0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
  }

  private static func linear(_ channel: Double) -> Double {
    if channel <= 0.04045 { return channel / 12.92 }
    return pow((channel + 0.055) / 1.055, 2.4)
  }

  private static func pixels(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.hasSuffix("px") else { return nil }
    return Double(trimmed.dropLast(2))
  }

  private static func fontWeight(_ text: String) -> Double? {
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "normal": return 400
    case "bold": return 700
    default: return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private static func parseRGB(_ text: String) -> ShaarA11yColor? {
    guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close
    else { return nil }
    let body = text[text.index(after: open)..<close]
    let parts = body.split { character in
      character == "," || character == "/" || character == " "
    }.map(String.init).filter { !$0.isEmpty }
    guard parts.count == 3 || parts.count == 4 else { return nil }
    guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2])
    else { return nil }
    let alpha = parts.count == 4 ? alphaValue(parts[3]) : 1
    guard let alpha else { return nil }
    return ShaarA11yColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func parseHex(_ text: String) -> ShaarA11yColor? {
    let hex = String(text.dropFirst())
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    switch hex.count {
    case 3, 4:
      let expanded = hex.map { "\($0)\($0)" }.joined()
      return parseHexDigits(expanded)
    case 6, 8:
      return parseHexDigits(hex)
    default:
      return nil
    }
  }

  private static func parseHexDigits(_ hex: String) -> ShaarA11yColor? {
    guard let value = UInt32(hex, radix: 16) else { return nil }
    if hex.count == 6 {
      return ShaarA11yColor(
        red: hexChannel(value >> 16), green: hexChannel(value >> 8), blue: hexChannel(value),
        alpha: 1)
    }
    return ShaarA11yColor(
      red: hexChannel(value >> 24), green: hexChannel(value >> 16), blue: hexChannel(value >> 8),
      alpha: Double(value & 0xff) / 255)
  }

  private static func hexChannel(_ value: UInt32) -> Double {
    Double(value & 0xff) / 255
  }

  private static func channel(_ text: String) -> Double? {
    if text.hasSuffix("%") {
      guard let value = Double(text.dropLast()) else { return nil }
      return value / 100
    }
    guard let value = Double(text) else { return nil }
    return value / 255
  }

  private static func alphaValue(_ text: String) -> Double? {
    if text.hasSuffix("%") {
      guard let value = Double(text.dropLast()) else { return nil }
      return value / 100
    }
    return Double(text)
  }
}

struct ShaarA11yDOMIndex: Equatable {
  var focus: [Int: Int]
  var contrast: [Int: Int]

  static func empty() -> ShaarA11yDOMIndex {
    ShaarA11yDOMIndex(focus: [:], contrast: [:])
  }

  static func walk(_ node: [String: Any]?) -> ShaarA11yDOMIndex {
    var focus: [Int: Int] = [:]
    var contrast: [Int: Int] = [:]
    guard let node else { return ShaarA11yDOMIndex(focus: focus, contrast: contrast) }
    _ = visit(node, depth: 0, seen: 0, focus: &focus, contrast: &contrast)
    return ShaarA11yDOMIndex(focus: focus, contrast: contrast)
  }

  static func read(attributes fields: [String: Any], nodeID: Int, into index: inout ShaarA11yDOMIndex)
  {
    let pairs = attributePairs(fields["attributes"])
    if let marker = pairs["data-shaar-focus"], let id = Int(marker) {
      index.focus[id] = nodeID
    }
    if let marker = pairs["data-shaar-contrast"], let id = Int(marker) {
      index.contrast[id] = nodeID
    }
  }

  private static func visit(
    _ node: [String: Any], depth: Int, seen: Int, focus: inout [Int: Int],
    contrast: inout [Int: Int]
  ) -> Int {
    guard depth <= 64, seen < 20_000 else { return seen }
    var count = seen + 1
    if let nodeID = ShaarA11yJSON.int(node["nodeId"]) {
      var index = ShaarA11yDOMIndex(focus: focus, contrast: contrast)
      read(attributes: node, nodeID: nodeID, into: &index)
      focus = index.focus
      contrast = index.contrast
    }
    for child in children(node) {
      count = visit(child, depth: depth + 1, seen: count, focus: &focus, contrast: &contrast)
    }
    return count
  }

  private static func children(_ node: [String: Any]) -> [[String: Any]] {
    var found: [[String: Any]] = []
    found.append(contentsOf: ShaarA11yJSON.objects(node["children"]))
    found.append(contentsOf: ShaarA11yJSON.objects(node["shadowRoots"]))
    if let frame = ShaarA11yJSON.object(node["contentDocument"]) { found.append(frame) }
    return found
  }

  static func attributePairs(_ value: Any?) -> [String: String] {
    let raw = ShaarA11yJSON.strings(value)
    guard raw.count.isMultiple(of: 2) else { return [:] }
    var pairs: [String: String] = [:]
    var index = 0
    while index + 1 < raw.count {
      pairs[raw[index]] = raw[index + 1]
      index += 2
    }
    return pairs
  }
}

enum ShaarA11yBox {
  static func viewportOrigin(_ result: [String: Any]?, scrollX: Double, scrollY: Double)
    -> ShaarA11yPoint?
  {
    guard let result, let model = ShaarA11yJSON.object(result["model"]) else { return nil }
    let quad = ShaarA11yJSON.doubles(model["border"]) ?? ShaarA11yJSON.doubles(model["content"])
    guard let quad, quad.count >= 8, quad.count.isMultiple(of: 2) else { return nil }
    var minX = quad[0]
    var minY = quad[1]
    var index = 0
    while index + 1 < quad.count {
      minX = min(minX, quad[index])
      minY = min(minY, quad[index + 1])
      index += 2
    }
    guard minX.isFinite, minY.isFinite else { return nil }
    return ShaarA11yPoint(x: minX - scrollX, y: minY - scrollY)
  }
}

enum ShaarA11yAXName {
  static func read(_ result: [String: Any]?) -> String? {
    guard let result, let first = ShaarA11yJSON.objects(result["nodes"]).first else { return nil }
    guard let name = ShaarA11yJSON.object(first["name"]), let value = name["value"] as? String
    else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(80))
  }
}

enum ShaarA11yJSON {
  static func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.intValue
  }

  static func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.doubleValue
  }

  static func doubles(_ value: Any?) -> [Double]? {
    if let value = value as? [Double] { return value }
    if let value = value as? [Int] { return value.map(Double.init) }
    guard let list = array(value) else { return nil }
    var numbers: [Double] = []
    for item in list {
      guard let number = double(item) else { return nil }
      numbers.append(number)
    }
    return numbers
  }

  static func flag(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return false
    }
    return number.boolValue
  }

  static func object(_ value: Any?) -> [String: Any]? {
    if let fields = value as? [String: Any] { return fields }
    guard let source = value as? NSDictionary else { return nil }
    var fields: [String: Any] = [:]
    for (key, item) in source {
      guard let name = key as? String else { continue }
      fields[name] = item
    }
    return fields
  }

  static func objects(_ value: Any?) -> [[String: Any]] {
    guard let list = array(value) else { return [] }
    return list.compactMap(object)
  }

  static func strings(_ value: Any?) -> [String] {
    if let value = value as? [String] { return value }
    guard let list = array(value) else { return [] }
    return list.compactMap { $0 as? String }
  }

  static func array(_ value: Any?) -> [Any]? {
    if let value = value as? [Any] { return value }
    if let value = value as? NSArray { return value.map { $0 as Any } }
    return nil
  }
}

enum ShaarA11yInventoryDecoder {
  static func decode(_ value: Any?) -> ShaarA11yInventory? {
    guard let fields = ShaarA11yJSON.object(value) else { return nil }
    let scrollX = ShaarA11yJSON.double(fields["scrollX"]) ?? 0
    let scrollY = ShaarA11yJSON.double(fields["scrollY"]) ?? 0
    let stops = ShaarA11yJSON.objects(fields["stops"]).compactMap(stop)
    let texts = ShaarA11yJSON.objects(fields["texts"]).compactMap(text)
    let truncated = ShaarA11yJSON.flag(fields["truncated"])
    return ShaarA11yInventory(
      scrollX: scrollX, scrollY: scrollY, stops: stops, texts: texts, truncated: truncated)
  }

  private static func stop(_ fields: [String: Any]) -> ShaarFocusStop? {
    guard let id = ShaarA11yJSON.int(fields["id"]),
      let tabIndex = ShaarA11yJSON.int(fields["tabIndex"]),
      let documentOrder = ShaarA11yJSON.int(fields["documentOrder"]),
      let name = fields["name"] as? String,
      let x = ShaarA11yJSON.double(fields["x"]),
      let y = ShaarA11yJSON.double(fields["y"])
    else { return nil }
    return ShaarFocusStop(
      id: id, tabIndex: tabIndex, documentOrder: documentOrder, name: name,
      origin: ShaarA11yPoint(x: x, y: y))
  }

  private static func text(_ fields: [String: Any]) -> ShaarA11yText? {
    guard let id = ShaarA11yJSON.int(fields["id"]),
      let snippet = fields["snippet"] as? String,
      let x = ShaarA11yJSON.double(fields["x"]),
      let y = ShaarA11yJSON.double(fields["y"])
    else { return nil }
    return ShaarA11yText(id: id, snippet: snippet, origin: ShaarA11yPoint(x: x, y: y))
  }
}
