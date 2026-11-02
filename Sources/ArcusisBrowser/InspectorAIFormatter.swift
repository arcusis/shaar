// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Markdown serialization has no clipboard, engine, clock or UI dependencies.
enum InspectorAIFormatter {
  struct Field: Codable, Equatable {
    let name: String
    let value: String
  }
  struct HTMLNode: Codable, Equatable {
    var tag: String? = nil
    var text: String? = nil
    var attributes: [Field] = []
    var children: [HTMLNode] = []
  }
  struct Bounds: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }
  struct Rule: Codable, Equatable {
    let selector: String
    let source: String
    let declarations: [Field]
  }
  struct Details: Codable, Equatable {
    var computed: [Field] = []
    var rules: [Rule] = []
    var consoleErrors: [String] = []
    var networkErrors: [String] = []
    var technologies: [String] = []
  }
  struct Context: Codable, Equatable {
    let id: Int
    var url: String
    var title: String
    var tag: String
    var accessibleName: String
    var role: String
    var selector: String
    var source: String
    var components: [String]
    var bounds: Bounds
    var classes: [String]
    var text: String
    var nearby: String
    var styles: [Field]
    var html: HTMLNode
    var ancestors: [String]
    var domPath: String
    var protected: Bool
    var details = Details()

    enum CodingKeys: String, CodingKey {
      case id, url, title, tag, accessibleName, role, selector, source, components, bounds, classes
      case text, nearby, styles, html, ancestors, domPath, protected
    }
    var valid: Bool {
      id > 0 && !protected && !InspectorAIFormatter.formTags.contains(tag.lowercased())
        && [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy {
          $0.isFinite && abs($0) < 1_000_000
        }
        && bounds.width >= 0 && bounds.height >= 0 && ancestors.count <= 64 && styles.count <= 512
    }
  }
  enum Intent: String, CaseIterable, Codable {
    case change = "Change"
    case question = "Question"
    case important = "Important"
  }
  struct Note: Identifiable, Equatable {
    let id: UUID
    let context: Context
    let intent: Intent
    let feedback: String
  }
  static let formTags: Set<String> = ["input", "textarea", "select", "option", "optgroup"]

  static func url(_ raw: String) -> String {
    guard !raw.isEmpty else { return "Unavailable" }
    guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return "Unavailable" }
    parts.query = nil
    parts.fragment = nil
    parts.user = nil
    parts.password = nil
    guard
      parts.scheme == nil
        || ["https", "http", "file", "webpack", "vite"].contains(parts.scheme?.lowercased() ?? "")
    else { return "[URL omitted]" }
    return parts.string ?? "Unavailable"
  }

  /// Remove URL suffixes even when URLs occur inside diagnostics, CSS or feedback.
  static func text(_ raw: String, limit: Int = 300) -> String {
    var value = raw.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
    }
    .map(String.init).joined()
    if let regex = try? NSRegularExpression(
      pattern: #"(?:https?|file|webpack|vite)://[^\s<>\"'`]+"#, options: [.caseInsensitive])
    {
      for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        .reversed()
      {
        guard let range = Range(match.range, in: value) else { continue }
        value.replaceSubrange(range, with: url(String(value[range])))
      }
    }
    return value.count > limit ? String(value.prefix(limit)) + "…" : value
  }

  static func inline(_ value: String, limit: Int = 300) -> String {
    text(value, limit: limit).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
      of: "\t", with: " "
    )
    .reduce(into: "") { result, character in
      if "\\`*_{}[]<>#|".contains(character) { result.append("\\") }
      result.append(character)
    }
  }
  static func code(_ value: String, limit: Int = 2048) -> String {
    let value = text(value, limit: limit).replacingOccurrences(of: "\n", with: " ")
    let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let marker = String(repeating: "`", count: max(1, longest + 1))
    return marker + " " + value + " " + marker
  }
  static func fence(_ value: String, language: String = "") -> String {
    let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let marker = String(repeating: "`", count: max(3, longest + 1))
    return marker + language + "\n" + value + "\n" + marker
  }
  static func number(_ value: Double) -> String {
    value.isFinite ? InspectorColor.number(value) : "Unavailable"
  }

  static func element(_ context: Context, detailed: Bool) -> String {
    guard context.valid else { return "Form controls and unavailable selections cannot be copied." }
    return
      "Attached browser context from \(url(context.url))\n\nSelected element:\n"
      + fields(context) + "\n\n" + content(context, detailed: detailed) + "\n"
  }

  static func notes(_ notes: [Note], detailed: Bool) -> String {
    let valid = notes.prefix(50).filter { $0.context.valid }
    var pages: [(String, String, [Note])] = []
    for note in valid {
      let key = url(note.context.url)
      if let index = pages.firstIndex(where: { $0.0 == key }) {
        pages[index].2.append(note)
      } else {
        pages.append((key, note.context.title, [note]))
      }
    }
    var sections: [String] = pages.count > 1 ? ["## Design Feedback across pages"] : []
    for (address, title, notes) in pages {
      var page =
        "## Design Feedback: \(inline(title.isEmpty ? address : title))\n\n**URL:** \(address)"
      for (index, note) in notes.enumerated() {
        let context = note.context
        let label = context.accessibleName.isEmpty ? context.tag : context.accessibleName
        page +=
          "\n\n### \(index + 1). \(inline(label))\n\n**Intent:** \(note.intent.rawValue)\n**Selector:** \(code(context.selector))\n**Source:** \(inline(url(context.source)))\n**Text:** \(inline(context.text))\n**Feedback:** \(inline(note.feedback, limit: 2000))"
        if detailed { page += "\n\n" + content(context, detailed: true) }
      }
      sections.append(page)
    }
    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func fields(_ c: Context) -> String {
    [
      "Tag: \(inline(c.tag))", "Accessible name: \(inline(c.accessibleName))",
      "Role: \(inline(c.role))",
      "Selector: \(code(c.selector))", "Source: \(inline(url(c.source)))",
      "React/components: \(c.components.isEmpty ? "Unavailable" : c.components.prefix(32).map { inline($0) }.joined(separator: " → "))",
      "Dimensions: \(number(c.bounds.width)) × \(number(c.bounds.height))",
    ].map { "- " + $0 }.joined(separator: "\n")
  }
  private static func content(_ c: Context, detailed: Bool) -> String {
    let defaults = [
      "display": "inline", "position": "static", "font-size": "16px", "color": "rgb(0, 0, 0)",
      "background-color": "rgba(0, 0, 0, 0)",
    ]
    let styles = c.styles.filter { defaults[$0.name] != nil && defaults[$0.name] != $0.value }
    var parts = [
      "Text content:\n" + fence(text(c.text)), "Nearby context:\n" + fence(text(c.nearby)),
      "Computed styles:\n"
        + fence(
          styles.map { "\($0.name): \(text($0.value, limit: 512));" }.joined(separator: "\n"),
          language: "css"),
      "HTML:\n" + fence(html(c.html), language: "html"),
      "Ancestor path: " + c.ancestors.prefix(64).map { inline($0) }.joined(separator: " > "),
      "Full DOM path: " + code(c.domPath, limit: 8192),
    ]
    if detailed {
      parts += [
        "Bounds: x=\(number(c.bounds.x)), y=\(number(c.bounds.y)), width=\(number(c.bounds.width)), height=\(number(c.bounds.height))",
        "Classes: " + c.classes.prefix(64).map { inline($0) }.joined(separator: " "),
        "Nearby elements:\n" + fence(text(c.nearby)),
        "Full computed styles:\n"
          + fence(
            c.details.computed.prefix(512).map {
              "\(text($0.name, limit: 128)): \(text($0.value, limit: 1024));"
            }.joined(separator: "\n"), language: "css"),
        "Matched CSS rules:\n"
          + c.details.rules.prefix(64).map { rule in
            "Source: \(inline(url(rule.source)))\n"
              + fence(
                text(rule.selector, limit: 2048) + " {\n"
                  + rule.declarations.prefix(128).map {
                    "  \(text($0.name, limit: 128)): \(text($0.value, limit: 1024));"
                  }.joined(separator: "\n") + "\n}", language: "css")
          }.joined(separator: "\n"),
        "Console errors:\n"
          + fence(c.details.consoleErrors.prefix(30).map { text($0) }.joined(separator: "\n")),
        "Network errors:\n"
          + fence(c.details.networkErrors.prefix(30).map { text($0) }.joined(separator: "\n")),
        "Tech stack: "
          + c.details.technologies.prefix(20).map { inline($0) }.joined(separator: ", "),
      ]
    }
    return parts.joined(separator: "\n\n")
  }

  static func html(_ root: HTMLNode) -> String {
    var visited = 0
    let excluded = formTags.union([
      "script", "style", "template", "noscript", "iframe", "object", "embed",
    ])
    let attributes: Set<String> = [
      "id", "class", "role", "aria-label", "title", "alt", "href", "src", "data-testid",
    ]
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    func render(_ node: HTMLNode, depth: Int) -> String {
      visited += 1
      guard depth < 12, visited <= 128 else { return "…" }
      guard let raw = node.tag else { return escaped(text(node.text ?? "")) }
      let tag = raw.lowercased()
      guard !excluded.contains(tag),
        tag.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
      else { return "" }
      let attrs = node.attributes.prefix(20).filter { attributes.contains($0.name.lowercased()) }
        .map {
          let name = $0.name.lowercased()
          let value = ["href", "src"].contains(name) ? url($0.value) : text($0.value)
          return " \(name)=\"\(escaped(value))\""
        }.joined()
      return "<\(tag)\(attrs)>" + node.children.map { render($0, depth: depth + 1) }.joined()
        + "</\(tag)>"
    }
    let value = render(root, depth: 0)
    guard value.utf8.count > 2048 else { return value }
    var result = ""
    for character in value {
      if result.utf8.count + String(character).utf8.count > 2045 { break }
      result.append(character)
    }
    return result + "…"
  }
}
