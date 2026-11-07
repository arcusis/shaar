// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@Suite struct ShaarDevToolsCSSOverviewTests {
  @Test func extractsColorsFontsAndMediaAndSkipsAnEmptySheet() {
    let summary = ShaarDevToolsCSSOverview.summarize([
      ShaarDevToolsCSSSheet(name: "site.css", url: "https://example.com/site.css", text: siteSheet),
      ShaarDevToolsCSSSheet(
        name: "empty.css", url: "https://example.com/empty.css", text: emptySheet),
      ShaarDevToolsCSSSheet(name: "type.css", url: "https://example.com/type.css", text: typeSheet),
    ])
    let colors = Dictionary(uniqueKeysWithValues: summary.colors.map { ($0.label, $0) })
    let fonts = Dictionary(uniqueKeysWithValues: summary.fonts.map { ($0.label, $0) })

    #expect(summary.examined == 3)
    #expect(colors["#336699"]?.count == 2)
    #expect(colors["#336699"]?.sheets == ["site.css"])
    #expect(colors["#abc"]?.count == 2)
    #expect(colors["rgb(255,255,255)"]?.count == 1)
    #expect(colors["rgba(0,0,0,0.4)"]?.count == 1)
    #expect(colors["red"]?.count == 2)
    #expect(colors["red"]?.sheets == ["type.css"])
    #expect(colors["#ff00ff"] == nil)
    #expect(colors["#abc123"] == nil)
    #expect(fonts["Iowan Old Style"]?.count == 2)
    #expect(fonts["Iowan Old Style"]?.sheets == ["site.css"])
    #expect(fonts["Georgia"]?.count == 1)
    #expect(fonts["serif"]?.count == 1)
    #expect(fonts["Local Sans"]?.count == 2)
    #expect(fonts["Local Sans"]?.sheets == ["type.css"])
    #expect(fonts["monospace"]?.count == 1)
    #expect(
      summary.media.map(\.label) == [
        "(min-width: 40em)", "(prefers-reduced-motion: reduce)",
      ])
    #expect(!summary.contributingSheets.contains("empty.css"))
    #expect(summary.sheets(matching: .color("#336699")) == ["site.css"])
    #expect(summary.sheets(matching: .font("Iowan Old Style")) == ["site.css"])
    #expect(summary.sheets(matching: .font("Local Sans")) == ["type.css"])
  }

  @Test func fontNamesAreNotCountedAsColors() {
    let summary = ShaarDevToolsCSSOverview.summarize([
      ShaarDevToolsCSSSheet(
        name: "brand.css", url: "https://example.com/brand.css",
        text: "p { font-family: \"Red Hat Text\", sans-serif; }")
    ])
    #expect(summary.colors.isEmpty)
    #expect(summary.fonts.map(\.label) == ["Red Hat Text", "sans-serif"])
  }

  @Test func duplicateSheetNamesStayDistinct() {
    let summary = ShaarDevToolsCSSOverview.summarize([
      ShaarDevToolsCSSSheet(
        name: "app.css", url: "https://a.example/app.css", text: "a { color: red }"),
      ShaarDevToolsCSSSheet(
        name: "app.css", url: "https://b.example/app.css", text: "b { color: blue }"),
    ])
    #expect(summary.sheets(matching: .color("red")) == ["https://a.example/app.css"])
    #expect(summary.sheets(matching: .color("blue")) == ["https://b.example/app.css"])
  }

  @Test func stylesheetRecognitionUsesTypeMimeAndPath() {
    #expect(
      ShaarDevToolsCSSOverview.isStylesheet(
        type: "Stylesheet", mimeType: "", url: "https://example.com/a"))
    #expect(
      ShaarDevToolsCSSOverview.isStylesheet(
        type: "Other", mimeType: "text/css", url: "https://example.com/a"))
    #expect(
      ShaarDevToolsCSSOverview.isStylesheet(
        type: "Other", mimeType: "", url: "https://example.com/app.css?v=1"))
    #expect(
      !ShaarDevToolsCSSOverview.isStylesheet(
        type: "Script", mimeType: "text/javascript", url: "https://example.com/app.js"))
    #expect(ShaarDevToolsCSSOverview.isLoadableSheetURL("https://example.com/app.css"))
    #expect(!ShaarDevToolsCSSOverview.isLoadableSheetURL("blob:https://example.com/sheet"))
  }

  @Test @MainActor func loadStylesheetsReadsStylesheetResourceContent() async throws {
    let record = CSSCommandRecord()
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      record.commands.append(command)
      switch command {
      case .resourceTree:
        return [
          "items": [
            [
              "url": "https://example.com/app.js", "type": "Script",
              "mimeType": "text/javascript",
            ],
            [
              "url": "https://example.com/site.css", "type": "Stylesheet",
              "mimeType": "text/css",
            ],
            [
              "url": "https://example.com/empty.css", "type": "Stylesheet",
              "mimeType": "text/css",
            ],
            ["url": "https://example.com/logo.png", "type": "Image", "mimeType": "image/png"],
            [
              "url": "blob:https://example.com/inline", "type": "Stylesheet",
              "mimeType": "text/css",
            ],
          ]
        ]
      case .resourceContent(let url):
        if url.hasSuffix("empty.css") {
          return ["items": [], "body": emptySheet, "base64Encoded": false]
        }
        return ["items": [], "body": "body { color: #336699; }", "base64Encoded": false]
      default:
        return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let sources = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    let batch = try await sources.loadStylesheets()
    phase2.close()

    let contentURLs = record.commands.compactMap { command -> String? in
      if case .resourceContent(let url) = command { return url }
      return nil
    }
    #expect(
      contentURLs == [
        "https://example.com/site.css",
        "https://example.com/empty.css",
      ])
    let summary = ShaarDevToolsCSSOverview.summarize(try #require(batch).sheets)
    #expect(summary.sheets(matching: .color("#336699")) == ["site.css"])
    #expect(!summary.contributingSheets.contains("empty.css"))
  }

  private let siteSheet = """
    body { color: #336699; background: rgb(255, 255, 255); }
    h1 { font-family: "Iowan Old Style", Georgia, serif; color: #336699; }
    .token { color: #ABC; }
    .token-2 { color: #abc; }
    @media (min-width: 40em) {
      .card { font: 700 16px/1.4 "Iowan Old Style"; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.4); }
    }
    """

  private let emptySheet = """
    /* color: #abc123 */
    .spacer { margin: 0; padding: 1rem; content: "#ff00ff"; }
    """

  private let typeSheet = """
    @font-face { font-family: "Local Sans"; src: url(font.woff2); }
    code { font-family: "Local Sans", monospace; color: red; }
    @media (prefers-reduced-motion: reduce) { code { color: red; } }
    """
}

@MainActor private final class CSSCommandRecord {
  var commands: [ShaarDevToolsPhase2Command] = []
}
