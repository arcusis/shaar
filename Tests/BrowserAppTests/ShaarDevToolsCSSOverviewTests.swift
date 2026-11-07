// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
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

  @Test @MainActor func cssOverviewRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    let emptyShell = cssShell()
    let empty = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: emptyShell), size: NSSize(width: 640, height: 280))
    emptyShell.cssOverview.present([])
    let none = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: emptyShell), size: NSSize(width: 640, height: 280))
    let blankShell = cssShell()
    blankShell.cssOverview.present([
      ShaarDevToolsCSSSheet(
        name: "blank.css", url: "https://example.com/blank.css", text: "a{margin:0}")
    ])
    let blank = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: blankShell), size: NSSize(width: 640, height: 280))
    let richShell = cssShell()
    richShell.cssOverview.present([
      ShaarDevToolsCSSSheet(name: "site.css", url: "https://example.com/site.css", text: siteSheet),
      ShaarDevToolsCSSSheet(name: "type.css", url: "https://example.com/type.css", text: typeSheet),
    ])
    richShell.cssOverview.choose(.color("#336699"))
    let colors = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: richShell), size: NSSize(width: 640, height: 520))
    richShell.cssOverview.choose(.font("Iowan Old Style"))
    let fonts = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: richShell), size: NSSize(width: 640, height: 520))
    richShell.cssOverview.failure = "Could not read style sheets."
    let failed = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: richShell), size: NSSize(width: 640, height: 520))
    let clipped = try await clippedOverview()
    let clippedImage = try VisualCapture.pngOffscreen(
      ShaarDevToolsCSSOverviewPanel(model: clipped), size: NSSize(width: 640, height: 360))
    let inspector = InspectorModel(target: richShell.target, engine: nil)
    richShell.open(inspector: inspector)
    richShell.section = .cssOverview
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: richShell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!empty.isEmpty)
    #expect(!none.isEmpty)
    #expect(!blank.isEmpty)
    #expect(!colors.isEmpty)
    #expect(!fonts.isEmpty)
    #expect(!failed.isEmpty)
    #expect(!clippedImage.isEmpty)
    #expect(clipped.cssOverview.summary.clipped)
    #expect(!panel.isEmpty)
    richShell.close()
    clipped.phase2.close()
  }

  @Test func mergingKeepsResourceFileTextAndAddsTheInlineSheet() {
    let resource = [
      ShaarDevToolsCSSSheet(
        name: "qa.css", url: "https://example.com/qa.css", text: ".qa-link { color: #c2410c; }"),
      ShaarDevToolsCSSSheet(
        name: "empty.css", url: "https://example.com/empty.css", text: "/* empty */"),
    ]
    let page = [
      ShaarDevToolsCSSSheet(
        name: "qa.css", url: "https://example.com/qa.css", text: ".qa-link { color: rgb(194, 65, 12); }"),
      ShaarDevToolsCSSSheet(
        name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }"),
    ]
    let merged = ShaarDevToolsCSSOverview.merging(page: page, resource: resource)
    #expect(merged.map(\.url) == [
      "https://example.com/qa.css",
      "https://example.com/empty.css",
      "https://example.com/#style-1",
    ])
    #expect(merged[0].text.contains("#c2410c"))
    let summary = ShaarDevToolsCSSOverview.summarize(merged)
    #expect(summary.examined == 3)
    #expect(summary.colors.contains { $0.label.contains("172033") })
    #expect(summary.colors.contains { $0.label.contains("c2410c") })
  }

  @Test func pageRowsDecodeInlineAndLinkedSheets() {
    let value: [[String: Any]] = [
      ["name": "style", "url": "https://example.com/#style-1", "text": "body { color: #172033; }"],
      ["name": "qa.css", "url": "https://example.com/qa.css", "text": ".qa-link { color: #c2410c; }"],
    ]
    let sheets = ShaarDevToolsCSSOverview.sheets(fromPage: value)
    #expect(sheets.map(\.name) == ["style", "qa.css"])
    #expect(sheets.map(\.url).count == 2)
  }

  @Test func pageRowsDecodeTheJSONShapeEvaluateReturns() throws {
    let data = Data(
      """
      [{"name":"style","url":"https://example.com/#style-1","text":"body { color: #172033; }"}]
      """.utf8)
    let value = try JSONSerialization.jsonObject(with: data)
    let sheets = ShaarDevToolsCSSOverview.sheets(fromPage: value)
    #expect(sheets.map(\.name) == ["style"])
    #expect(sheets.first?.text.contains("#172033") == true)
  }

  @Test func mergingFillsAnEmptyResourceBodyFromThePage() {
    let resource = [
      ShaarDevToolsCSSSheet(name: "qa.css", url: "https://example.com/qa.css", text: ""),
      ShaarDevToolsCSSSheet(name: "empty.css", url: "https://example.com/empty.css", text: ""),
    ]
    let page = [
      ShaarDevToolsCSSSheet(
        name: "qa.css", url: "https://example.com/qa.css",
        text: ".qa-link { color: rgb(194, 65, 12); }"),
    ]
    let merged = ShaarDevToolsCSSOverview.merging(page: page, resource: resource)
    #expect(merged.map(\.name) == ["qa.css", "empty.css"])
    #expect(merged[0].text.contains("rgb(194, 65, 12)"))
    #expect(merged[1].text.isEmpty)
  }

  @Test @MainActor func reloadCountsInlineSheetsTheResourceTreeSkipped() async {
    let shell = cssShell()
    shell.cssOverview.attach {
      [
        ShaarDevToolsCSSSheet(
          name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }")
      ]
    }
    await shell.cssOverview.reload()
    #expect(shell.cssOverview.loaded)
    #expect(shell.cssOverview.failure == nil)
    #expect(shell.cssOverview.summary.examined == 1)
    #expect(shell.cssOverview.summary.colors.contains { $0.label.contains("172033") })
    shell.close()
  }

  @Test @MainActor func reloadSeesASheetAddedOnTheNextRead() async {
    let shell = cssShell()
    let reads = CSSSheetReads()
    shell.cssOverview.attach {
      reads.count += 1
      if reads.count == 1 {
        return [
          ShaarDevToolsCSSSheet(
            name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }")
        ]
      }
      return [
        ShaarDevToolsCSSSheet(
          name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }"),
        ShaarDevToolsCSSSheet(
          name: "added", url: "https://example.com/#style-2", text: ".qa-added { color: #0f766e; }"),
      ]
    }
    await shell.cssOverview.reload()
    #expect(shell.cssOverview.summary.examined == 1)
    await shell.cssOverview.reload(force: true)
    #expect(shell.cssOverview.summary.examined == 2)
    #expect(shell.cssOverview.summary.colors.contains { $0.label.contains("0f766e") })
    shell.close()
  }

  @Test @MainActor func forceReloadDuringAReadRunsAgainWhenThePageAddsASheet() async {
    let shell = cssShell()
    let reads = CSSSheetReads()
    shell.cssOverview.attach {
      reads.count += 1
      if reads.count == 1 {
        await shell.cssOverview.reload(force: true)
        return [
          ShaarDevToolsCSSSheet(
            name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }")
        ]
      }
      return [
        ShaarDevToolsCSSSheet(
          name: "style", url: "https://example.com/#style-1", text: "body { color: #172033; }"),
        ShaarDevToolsCSSSheet(
          name: "added", url: "https://example.com/#style-2", text: ".qa-added { color: #0f766e; }"),
      ]
    }
    await shell.cssOverview.reload()
    for _ in 0..<30 where reads.count < 2 {
      await Task.yield()
    }
    #expect(reads.count == 2)
    #expect(shell.cssOverview.summary.examined == 2)
    #expect(shell.cssOverview.summary.colors.contains { $0.label.contains("0f766e") })
    shell.close()
  }

  @Test @MainActor func reloadReportsAPageThatHasNoStyleSheets() async {
    let shell = cssShell()
    shell.cssOverview.attach { [] }
    await shell.cssOverview.reload()
    #expect(shell.cssOverview.loaded)
    #expect(shell.cssOverview.failure == nil)
    #expect(shell.cssOverview.summary.examined == 0)
    shell.close()
  }

  @Test @MainActor func reloadDoesNotClaimAnEmptyPageWhenThePageReadFails() async {
    let shell = cssShell()
    shell.cssOverview.attach {
      throw InspectorFailure("The page could not be read.")
    }
    await shell.cssOverview.reload()
    #expect(!shell.cssOverview.loaded)
    #expect(shell.cssOverview.failure == "The page could not be read.")
    #expect(shell.cssOverview.summary.examined == 0)
    shell.close()
  }

  @MainActor private func cssShell() -> ShaarDevToolsModel {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCSS.\(UUID().uuidString)")!
    return ShaarDevToolsModel(target: cssTarget(), layoutDefaults: defaults)
  }

  private func cssTarget() -> SiteControlTarget {
    SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
  }

  @MainActor private func clippedOverview() async throws -> ShaarDevToolsModel {
    let urls = (0..<33).map { "https://example.com/sheet-\($0).css" }
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return [
          "items": urls.map { url in
            ["url": url, "type": "Stylesheet", "mimeType": "text/css"]
          }
        ]
      case .resourceContent:
        return ["items": [], "body": "a{color:#336699}", "base64Encoded": false]
      default:
        return ["items": []]
      }
    }
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCSS.\(UUID().uuidString)")!
    let shell = ShaarDevToolsModel(
      target: cssTarget(), phase2Transport: fixture, layoutDefaults: defaults)
    shell.phase2.open()
    for _ in 0..<40 where !shell.phase2.available { await Task.yield() }
    #expect(shell.phase2.available)
    await shell.cssOverview.reload()
    return shell
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

@MainActor private final class CSSSheetReads {
  var count = 0
}
