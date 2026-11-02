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

  static func element(
    _ context: Context, detailed: Bool, screenshotPath: String? = nil
  ) -> String {
    guard context.valid else { return "Form controls and unavailable selections cannot be copied." }
    let screenshot =
      screenshotPath.map { "\nScreenshot: " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
    return
      "Attached browser context from \(url(context.url))\(screenshot)\n\nSelected element:\n"
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
          "\n\n### \(index + 1). \(inline(label))\n\n**Intent:** \(note.intent.rawValue)\n**Selector:** \(code(context.selector))"
        if available(context.source) { page += "\n**Source:** \(inline(url(context.source)))" }
        if available(context.text) { page += "\n**Text:** \(inline(excerpt(context.text)))" }
        page += "\n**Feedback:** \(inline(note.feedback, limit: 2000))"
        if detailed { page += "\n\n" + content(context, detailed: true) }
      }
      sections.append(page)
    }
    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func fields(_ c: Context) -> String {
    var fields = ["Tag: \(inline(c.tag))"]
    if !c.accessibleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      fields.append("Accessible name: \(inline(c.accessibleName))")
    }
    if available(c.role) { fields.append("Role: \(inline(c.role))") }
    if available(c.selector) { fields.append("Selector: \(code(c.selector))") }
    if available(c.source) { fields.append("Source: \(inline(url(c.source)))") }
    let components = c.components.prefix(32).filter(readableComponent)
    if !components.isEmpty {
      fields.append("React/components: " + components.map { inline($0) }.joined(separator: " → "))
    }
    fields.append(
      "Dimensions: \(number(c.bounds.width.rounded())) × \(number(c.bounds.height.rounded()))")
    return fields.map { "- " + $0 }.joined(separator: "\n")
  }

  static func readableComponent(_ raw: String) -> Bool {
    let name = raw.components(separatedBy: ": ").last ?? raw
    guard name.count >= 3, name.count <= 160,
      !["Anonymous", "Unknown", "Component", "ForwardRef", "Memo"].contains(name)
    else { return false }
    return name.range(
      of:
        #"^(?:[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*(?:\([A-Za-z0-9_.]+\))?|[a-z]{3,}(?:[-_][a-z]{3,})+)$"#,
      options: .regularExpression) != nil
  }

  static func available(_ value: String) -> Bool {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty && value != "Unavailable"
      && value != "Unavailable: Page diagnostics have not been enabled."
  }

  static func excerpt(_ raw: String, limit: Int = 300) -> String {
    let value = text(raw, limit: .max).trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count > limit else { return value }
    let prefix = String(value.prefix(limit))
    guard let end = prefix.lastIndex(where: { $0.isWhitespace }) else { return "…" }
    return prefix[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
  private static func content(_ c: Context, detailed: Bool) -> String {
    let defaults = [
      "display": "inline", "position": "static", "font-size": "16px", "color": "rgb(0, 0, 0)",
      "background-color": "rgba(0, 0, 0, 0)",
    ]
    let styles = c.styles.filter { defaults[$0.name] != nil && defaults[$0.name] != $0.value }
    let own = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = c.accessibleName.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set<String>()
    let nearby = c.nearby.split(separator: "\n").map(String.init).filter {
      available($0) && (own.isEmpty || !$0.contains(own)) && (name.isEmpty || !$0.contains(name))
        && seen.insert($0).inserted
    }.joined(separator: "\n")
    var parts: [String] = []
    if !own.isEmpty, own != name { parts.append("Text content:\n" + fence(excerpt(own))) }
    if available(nearby) {
      parts.append((detailed ? "Nearby elements:\n" : "Nearby context:\n") + fence(excerpt(nearby)))
    }
    if !styles.isEmpty {
      parts.append(
        "Computed styles:\n"
          + fence(
            styles.map { "\($0.name): \(text($0.value, limit: 512));" }.joined(separator: "\n"),
            language: "css"))
    }
    let snippet = html(c.html)
    if !snippet.isEmpty { parts.append("HTML:\n" + fence(snippet, language: "html")) }
    if !c.ancestors.isEmpty {
      parts.append(
        "Ancestor path: " + c.ancestors.prefix(64).map { inline($0) }.joined(separator: " > "))
    }
    if available(c.domPath) { parts.append("Full DOM path: " + code(c.domPath, limit: 8192)) }
    if detailed {
      parts.append(
        "Bounds: x=\(number(c.bounds.x)), y=\(number(c.bounds.y)), width=\(number(c.bounds.width)), height=\(number(c.bounds.height))"
      )
      if !c.classes.isEmpty {
        parts.append("Classes: " + c.classes.prefix(64).map { inline($0) }.joined(separator: " "))
      }
      if !c.details.computed.isEmpty {
        parts.append(
          "Full computed styles:\n"
            + fence(
              c.details.computed.prefix(512).map {
                "\(text($0.name, limit: 128)): \(text($0.value, limit: 1024));"
              }.joined(separator: "\n"), language: "css"))
      }
      if !c.details.rules.isEmpty {
        parts.append(
          "Matched CSS rules:\n"
            + c.details.rules.prefix(64).map { rule in
              (available(rule.source) ? "Source: \(inline(url(rule.source)))\n" : "")
                + fence(
                  text(rule.selector, limit: 2048) + " {\n"
                    + rule.declarations.prefix(128).map {
                      "  \(text($0.name, limit: 128)): \(text($0.value, limit: 1024));"
                    }.joined(separator: "\n") + "\n}", language: "css")
            }.joined(separator: "\n"))
      }
      for (title, values) in [
        ("Console errors", c.details.consoleErrors), ("Network errors", c.details.networkErrors),
      ] {
        let values = values.prefix(30).filter(available)
        if !values.isEmpty {
          parts.append(title + ":\n" + fence(values.map { text($0) }.joined(separator: "\n")))
        }
      }
      let technologies = c.details.technologies.prefix(20).filter(available)
      if !technologies.isEmpty {
        parts.append("Tech stack: " + technologies.map { inline($0) }.joined(separator: ", "))
      }
    }
    return parts.joined(separator: "\n\n")
  }

  static func html(_ root: HTMLNode) -> String {
    let excluded = formTags.union([
      "script", "style", "template", "noscript", "iframe", "object", "embed",
    ])
    let attributes: Set<String> = [
      "id", "class", "role", "aria-label", "title", "alt", "href", "src", "data-testid",
      "data-test", "data-qa",
    ]
    let voidTags: Set<String> = [
      "area", "base", "br", "col", "hr", "img", "link", "meta", "param", "source", "track", "wbr",
    ]
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    func opening(_ node: HTMLNode) -> (String, String)? {
      guard let raw = node.tag else { return nil }
      let tag = raw.lowercased()
      guard !excluded.contains(tag),
        tag.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
      else { return nil }
      var result = "<" + tag
      for attribute in node.attributes.prefix(20)
      where attributes.contains(attribute.name.lowercased()) {
        let name = attribute.name.lowercased()
        var value =
          ["href", "src"].contains(name) ? url(attribute.value) : text(attribute.value, limit: 120)
        if ["href", "src"].contains(name), value.count > 96 {
          value = String(value.prefix(45)) + "…" + String(value.suffix(40))
        }
        let field = " \(name)=\"\(escaped(value))\""
        if result.utf8.count + field.utf8.count < 700 { result += field }
      }
      return (result + ">", voidTags.contains(tag) ? "" : "</\(tag)>")
    }
    guard let tag = root.tag else { return escaped(excerpt(root.text ?? "")) }
    guard let (start, end) = opening(root) else { return "" }
    guard !voidTags.contains(tag.lowercased()) else { return start }
    var result = start
    for child in root.children.prefix(64) {
      let fragment: String
      if child.tag != nil {
        guard let (start, end) = opening(child) else { continue }
        fragment = "\n  " + start + (end.isEmpty ? "" : "…" + end)
      } else {
        fragment = escaped(excerpt(child.text ?? "", limit: 120))
      }
      if result.utf8.count + fragment.utf8.count + end.utf8.count + 5 > 2048 {
        result += "…"
        break
      }
      result += fragment
    }
    return result + (result.contains("\n") ? "\n" : "") + end
  }
}
