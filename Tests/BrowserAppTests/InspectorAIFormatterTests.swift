// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct InspectorAIFormatterTests {
  typealias F = InspectorAIFormatter
  @Test func singleElementSnapshot() throws {
    try snapshot(
      F.element(
        Self.context(), detailed: false,
        screenshotPath: "/Users/developer/Library/Caches/Shaar/Inspector/123-button.png"), "element"
    )
  }
  @Test func qualitySnapshotOmitsUnnecessaryFieldsAndPrunesWholeTags() throws {
    var value = Self.context()
    value.accessibleName = ""
    value.tag = "section"
    value.role = "Unavailable"
    value.source = "Unavailable"
    value.selector = "[data-qa=account-card]"
    value.ancestors = ["html", "body", "section"]
    value.domPath = "html > body > section:nth-of-type(1)"
    value.components = ["bt", "React: ProductCard", "x", "ab12", "Anonymous"]
    value.bounds = .init(x: 20.2, y: 40.9, width: 180.4, height: 48.7)
    value.text = "Account details"
    value.nearby = "main: Account details Cancel\nbutton: Cancel\nbutton: Cancel"
    value.html = .init(
      tag: "section", attributes: [.init(name: "data-qa", value: "account-card")],
      children: [
        .init(tag: "h2", children: [.init(text: "Account details")]),
        .init(tag: "div", children: [.init(tag: "span", children: [.init(text: "Deep content")])]),
        .init(
          tag: "img",
          attributes: [
            .init(
              name: "src",
              value: "https://example.com/" + String(repeating: "long/", count: 35)
                + "image.png?secret=value")
          ]),
      ])
    let result = F.element(
      value, detailed: false,
      screenshotPath: "/Users/developer/Library/Caches/Shaar/Inspector/123-section.png")
    try snapshot(result, "quality")
    #expect(!result.contains("Unavailable") && !result.contains("Accessible name:"))
    #expect(!result.contains("Deep content") && !result.contains("<span>"))
    #expect(result.contains("Dimensions: 180 × 49"))
    #expect(!result.contains("React/components: bt") && result.contains("React: ProductCard"))
    #expect(F.excerpt("alpha beta gamma delta", limit: 13) == "alpha beta…")
    value.accessibleName = value.text
    #expect(!F.element(value, detailed: false).contains("Text content:"))
    #expect(F.readableComponent("App") && !F.readableComponent("bt"))
    #expect(F.html(value.html).hasSuffix("</section>"))
  }
  @Test func detailedOnAndOffSnapshots() throws {
    let context = Self.context()
    try snapshot(F.element(context, detailed: true), "detailed")
    #expect(!F.element(context, detailed: false).contains("Full computed styles"))
    #expect(F.element(context, detailed: true).contains("line-height: 24px"))
  }
  @Test func authoredContentIsNotMistakenForMetadataPlaceholders() {
    var value = Self.context()
    value.accessibleName = "Unavailable"
    value.source = "UnavailableCard.tsx"
    value.details.consoleErrors = [
      "Unavailable backend after login", "Unavailable: Page diagnostics have not been enabled.",
    ]
    let result = F.element(value, detailed: true)
    #expect(result.contains("Accessible name: Unavailable"))
    #expect(result.contains("Source: UnavailableCard.tsx"))
    #expect(result.contains("Unavailable backend after login"))
    #expect(!result.contains("Page diagnostics have not been enabled"))
  }
  @Test func notesAcrossTwoPagesSnapshot() throws {
    let one = Self.context()
    var anotherQuery = one
    anotherQuery.url = "https://example.com/account?different=secret#two"
    var two = one
    two.url = "https://example.com/settings?token=secret#panel"
    two.title = "Settings"
    let notes: [F.Note] = [
      .init(id: UUID(), context: one, intent: .change, feedback: "Increase padding."),
      .init(id: UUID(), context: two, intent: .question, feedback: "Should this be primary?"),
      .init(
        id: UUID(), context: anotherQuery, intent: .important,
        feedback: "Keep keyboard focus visible."),
    ]
    try snapshot(F.notes(notes, detailed: false), "notes-two-pages")
    try snapshot(F.notes(notes, detailed: true), "notes-two-pages-detailed")
    #expect(F.notes(notes, detailed: true).contains("Full computed styles"))
    #expect(!F.notes(notes, detailed: false).contains("token="))
  }
  @Test func sanitizationSnapshotAndPrivacyBounds() throws {
    var context = Self.context()
    context.url = "https://user:credential@example.com/path?token=secret#private"
    context.text = "Text with https://example.com/x?token=secret#private and \u{0000}control."
    context.html = .init(
      tag: "div", attributes: [.init(name: "onclick", value: "secret")],
      children: [
        .init(
          tag: "input",
          attributes: [
            .init(name: "type", value: "password"), .init(name: "value", value: "password-secret"),
          ]),
        .init(tag: "textarea", children: [.init(text: "textarea-secret")]),
        .init(
          tag: "select",
          children: [.init(tag: "option", children: [.init(text: "selected-secret")])]),
        .init(
          tag: "a",
          attributes: [
            .init(name: "href", value: "https://example.com/x?auth=secret#f"),
            .init(name: "value", value: "attribute-secret"),
          ], children: [.init(text: "Safe <text> ```")]),
      ])
    let value = F.element(context, detailed: true)
    try snapshot(value, "sanitization")
    for secret in [
      "credential", "token=", "password-secret", "textarea-secret", "selected-secret",
      "attribute-secret", "onclick",
    ] { #expect(!value.contains(secret)) }
    context.text = String(repeating: "x", count: 1000)
    #expect(!F.element(context, detailed: false).contains(String(repeating: "x", count: 301)))
    let html = F.html(
      .init(
        tag: "div", children: (0..<128).map { _ in .init(text: String(repeating: "界", count: 300)) }
      ))
    #expect(html.utf8.count <= 2048)
    #expect(F.fence("```\nunsafe\n```").hasPrefix("````\n"))
    #expect(F.url("javascript:alert(1)") == "[URL omitted]")
    context.tag = "input"
    context.protected = true
    #expect(
      F.element(context, detailed: true)
        == "Form controls and unavailable selections cannot be copied.")
  }
  static func context() -> F.Context {
    var context = F.Context(
      id: 8, url: "https://example.com/account?session=secret#form", title: "Account",
      tag: "button",
      accessibleName: "Save", role: "button", selector: "#save", source: "/src/SaveButton.tsx:12",
      components: ["React: SaveButton"],
      bounds: .init(x: 20, y: 40, width: 180, height: 48), classes: ["primary"],
      text: "Save changes", nearby: "main: Save changes Cancel",
      styles: [
        .init(name: "display", value: "inline-block"), .init(name: "position", value: "static"),
        .init(name: "font-size", value: "16px"), .init(name: "color", value: "rgb(0, 0, 0)"),
        .init(name: "background-color", value: "rgba(0, 0, 0, 0)"),
      ],
      html: .init(
        tag: "button", attributes: [.init(name: "id", value: "save")],
        children: [.init(text: "Save changes")]),
      ancestors: ["html", "body", "main", "button"],
      domPath: "html > body > main > button:nth-of-type(1)", protected: false)
    context.details = .init(
      computed: [.init(name: "line-height", value: "24px")],
      rules: [
        .init(
          selector: "#save", source: "https://example.com/app.css?version=secret#L2",
          declarations: [.init(name: "padding", value: "12px")])
      ], consoleErrors: ["Error loading https://example.com/api?auth=secret#x"],
      networkErrors: ["GET https://example.com/api?auth=secret#x — status 500"],
      technologies: ["React"])
    return context
  }
  private func snapshot(_ value: String, _ name: String) throws {
    if ProcessInfo.processInfo.environment["UPDATE_INSPECTOR_AI_SNAPSHOTS"] == "1" {
      let root = URL(filePath: #filePath).deletingLastPathComponent().appending(
        path: "Snapshots/InspectorAI")
      try value.write(to: root.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
      return
    }
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "InspectorAI"))
    #expect(value == (try String(contentsOf: file, encoding: .utf8)))
  }
}
