// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@Suite @MainActor struct ShaarSourcesModelTests {
  @Test func fiveMegabyteSourceFixtureIsFullyDisplayed() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let content = ShaarPhase2FixtureTransport.fiveMiBSource
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "https://example.com/app.js", "type": "Script"]]]
      case .resourceContent:
        return ["items": [], "body": content, "base64Encoded": false]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    #expect(model.failure == nil)
    #expect(model.displayedContent?.utf8.count == content.utf8.count)
    let start = ContinuousClock.now
    #expect(model.displayedLines?.count == 52_429)
    #expect(model.displayedLines?.last.map(String.init) == String(repeating: "x", count: 80))
    #expect(model.visibleLineRange == 0..<500)
    #expect(model.sourcePageCount == 105)
    for _ in 0..<104 { model.showNextSourcePage() }
    #expect(model.visibleLineRange == 52_000..<52_429)
    model.showNextSourcePage()
    #expect(model.visibleLineRange == 52_000..<52_429)
    model.showPreviousSourcePage()
    #expect(model.visibleLineRange == 51_500..<52_000)
    let elapsed = start.duration(to: .now)
    print("Sources 5 MiB line index: \(elapsed)")
    #expect(elapsed < .seconds(2))
    #expect(!model.truncated)
    phase2.close()
  }

  @Test func inspectorContentRecoversFromNativeReplyLimit() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let url = "https://example.com/app.js"
    let content = ShaarPhase2FixtureTransport.fiveMiBSource
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": url, "type": "Script"]]]
      case .resourceContent:
        throw InspectorFailure("native reply exceeds limit")
      default:
        return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(
      phase2: phase2,
      inspectorContent: { selectedURL, selectedTarget in
        #expect(selectedURL == url)
        #expect(selectedTarget == target)
        return (content, false)
      })
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    #expect(model.displayedContent?.utf8.count == content.utf8.count)
    #expect(model.displayedLines?.count == 52_429)
    #expect(!model.truncated)
    #expect(model.failure == nil)
    phase2.close()
  }

  @Test func inspectorFrameLookupUsesTheMatchingResourceFrame() {
    let tree: [String: Any] = [
      "frameTree": [
        "frame": ["id": "root"],
        "resources": [["url": "https://example.com/other.js"]],
        "childFrames": [
          [
            "frame": ["id": "child"],
            "resources": [["url": "https://example.com/app.js"]],
          ]
        ],
      ]
    ]
    #expect(
      ShaarInspectorSourceLoader.frameID(for: "https://example.com/app.js", in: tree)
        == "child")
    #expect(
      ShaarInspectorSourceLoader.frameID(for: "https://example.com/missing.js", in: tree)
        == nil)
  }

  @Test func resourceListContentFilteringAndPrettyJSON() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return [
          "items": [
            ["url": "https://example.com/app.js", "type": "Script", "mimeType": "text/javascript"],
            [
              "url": "https://example.com/config.json", "type": "Other",
              "mimeType": "application/json",
            ],
            ["url": "https://example.com/logo.png", "type": "Image", "mimeType": "image/png"],
          ]
        ]
      case .resourceContent(let url):
        if url.hasSuffix("config.json") {
          return ["items": [], "body": "{\"enabled\":true,\"count\":2}", "base64Encoded": false]
        }
        if url.hasSuffix("logo.png") {
          return ["items": [], "body": "iVBORw0KGgo=", "base64Encoded": true]
        }
        return ["items": [], "body": "const answer = 42;", "base64Encoded": false]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    #expect(model.resources.count == 3)
    #expect(model.displayedContent == "const answer = 42;")
    model.search = "config"
    #expect(model.visibleResources.map(\.name) == ["config.json"])
    await model.select(try #require(model.visibleResources.first))
    model.prettyPrint = true
    #expect(model.isJSON)
    #expect(model.displayedContent?.contains("\n") == true)
    #expect(model.displayedContent?.contains("\"enabled\" : true") == true)
    await model.select(try #require(model.resources.first { $0.name == "logo.png" }))
    #expect(model.binary && model.displayedContent == nil)
    model.reset()
    #expect(model.resources.isEmpty && model.selectedURL == nil)
    phase2.close()
  }

  @Test func fileTreeSearchPrettyPrintAndLineReveal() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return [
          "items": [
            ["url": "https://example.com/app.js", "type": "Script", "mimeType": "text/javascript"],
            [
              "url": "https://example.com/src/panel.js", "type": "Script",
              "mimeType": "text/javascript",
            ],
            [
              "url": "https://example.com/config.json", "type": "Other",
              "mimeType": "application/json",
            ],
          ]
        ]
      case .resourceContent(let url):
        if url.hasSuffix("config.json") {
          return ["items": [], "body": "{\"enabled\":true}", "base64Encoded": false]
        }
        if url.hasSuffix("panel.js") {
          return [
            "items": [],
            "body": "function panel(){const label=\"a;b\";return label;}\n",
            "base64Encoded": false,
          ]
        }
        return [
          "items": [],
          "body": "const answer = 42;\nexport function render(){return answer;}\n",
          "base64Encoded": false,
        ]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    let names = model.treeRows.map(\.name)
    let sourceFolder = try #require(names.firstIndex(of: "src"))
    let panelFile = try #require(names.firstIndex(of: "panel.js"))
    #expect(names.contains("example.com"))
    #expect(sourceFolder < panelFile)
    let panel = try #require(model.resources.first { $0.name == "panel.js" })
    await model.select(panel)
    model.prettyPrint = true
    #expect(model.displayedContent?.contains("\n") == true)
    #expect(model.displayedContent?.contains("\"a;b\"") == true)
    model.contentQuery = "label"
    model.revealCurrentMatch()
    #expect(model.matchLines.count == 2)
    #expect(model.highlightedLine == model.matchLines.first)
    let revealed = await model.reveal(url: "https://example.com/app.js?build=1", line: 2)
    #expect(revealed)
    #expect(model.prettyPrint == false)
    #expect(model.selectedURL == "https://example.com/app.js")
    #expect(model.highlightedLine == 1)
    #expect(model.displayedLines?[1].contains("render") == true)
    model.contentQuery = ""
    model.revealCurrentMatch()
    #expect(model.highlightedLine == 1)
    let missing = await model.reveal(url: "https://other.test/app.js", line: 1)
    #expect(!missing)
    phase2.close()
  }

  @Test func consoleStackFramesExposeDocumentLines() {
    let message = """
      Error: shaar-source-jump
          at shaarThrowForSources (http://127.0.0.1:9/inspector-tools:8:40)
          at http://127.0.0.1:9/inspector-source-sample.js:1:1
          at <anonymous>:1:1
      """
    let frames = ShaarConsoleLocations.frames(in: message)
    #expect(frames.count == 2)
    #expect(frames[0].function == "shaarThrowForSources")
    let location = ShaarConsoleLocations.parse(frames[0].source)
    #expect(location?.url == "http://127.0.0.1:9/inspector-tools")
    #expect(location?.line == 8)
    #expect(location?.column == 40)
    let sample = ShaarConsoleLocations.parse(frames[1].source)
    #expect(sample?.url == "http://127.0.0.1:9/inspector-source-sample.js")
    #expect(sample?.line == 1)
    #expect(sample?.column == 1)
    #expect(ShaarConsoleLocations.parse("/app/main.ts:8") == nil)
    #expect(ShaarConsoleLocations.parse("http://127.0.0.1:9") == nil)
    let formatted = ShaarSourceFormatter.layout(
      "for (let i = 0; i < 2; i++) { work(); }")
    #expect(formatted.contains("for (let i = 0; i < 2; i++)"))
    #expect(formatted.contains("work();"))
  }

  @Test func prettyPrintKeepsRegexAndTemplateLiteralsInMinifiedScript() {
    let source =
      #"const re=/https?:\/\/[^{};]+/g;function match(url){const label=`a;${url}`;return re.test(url)&&label.length>0;}"#
    let formatted = ShaarSourceFormatter.layout(source)
    #expect(formatted.contains(#"/https?:\/\/[^{};]+/g"#))
    #expect(formatted.contains(#"`a;${url}`"#))
    #expect(formatted.split(separator: "\n").count >= 5)
    #expect(formatted.contains("return re.test(url)&&label.length>0;"))
    let afterCondition = ShaarSourceFormatter.layout("if(ok)/[{};]/.test(value);")
    #expect(afterCondition.contains("/[{};]/.test(value);"))
  }

  @Test func productionPendingTransportShowsNoResources() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let phase2 = ShaarPhase2Model(target: target, transport: ShaarPhase2PendingTransport())
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    await model.refresh()
    #expect(model.resources.isEmpty && model.content == nil && !phase2.available)
    phase2.close()
  }

  @Test func localResourceUsesWorkspaceMetadataAndSourceMap() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "src/app.ts")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("export const app = true".utf8).write(to: file)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "http://localhost:3000/app.js", "type": "Script"]]]
      case .resourceContent:
        return [
          "items": [], "body": "console.log(1);\n//# sourceMappingURL=app.js.map",
          "base64Encoded": false,
        ]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(
      phase2: phase2,
      loadSourceData: { url in
        if url.path.hasSuffix("com.chrome.devtools.json") {
          return Data(#"{"workspace":{"root":"\#(root.path)"}}"#.utf8)
        }
        return Data(#"{"version":3,"sources":["webpack://_N_E/./src/app.ts"]}"#.utf8)
      })
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    await model.findLocalFiles(framework: .nextJS)
    #expect(model.localFiles.map(\.path) == [file.path])
    #expect(model.sourceFailure == nil)
    phase2.close()
  }

  @Test func sourceMapsAddOriginalFilesWithEmbeddedContent() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1:3211/")!)
    let map =
      #"{"version":3,"sourceRoot":"webpack://_N_E/","sources":["./src/App.vue","./src/main.ts"],"sourcesContent":["<template>App</template>","export const answer: number = 42"]}"#
    let inline = Data(map.utf8).base64EncodedString()
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "http://127.0.0.1:3211/assets/app.js", "type": "Script"]]]
      case .resourceContent:
        return [
          "items": [],
          "body": "console.log(1);\n//# sourceMappingURL=data:application/json;base64,\(inline)",
          "base64Encoded": false,
        ]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    #expect(model.treeRows.map(\.name).contains("Original sources"))
    #expect(model.treeRows.map(\.name).contains("App.vue"))
    #expect(model.treeRows.map(\.name).contains("main.ts"))
    let original = try #require(model.resources.first { $0.name == "App.vue" })
    await model.select(original)
    #expect(model.content == "<template>App</template>")
    await model.refresh()
    #expect(model.resources.contains { $0.url == original.url })
    #expect(model.content == "<template>App</template>")
    phase2.close()
  }

  @Test func externalSourceMapLoadsOriginalTypeScript() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "https://example.test/assets/main.js", "type": "Script"]]]
      case .resourceContent:
        return [
          "items": [], "body": "(()=>{})();\n//# sourceMappingURL=main.js.map",
          "base64Encoded": false,
        ]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target, transport: fixture)
    let model = ShaarSourcesModel(
      phase2: phase2,
      loadSourceData: { url in
        #expect(url.absoluteString == "https://example.test/assets/main.js.map")
        return Data(
          #"{"version":3,"sources":["../src/main.ts"],"sourcesContent":["const answer: number = 42"]}"#
            .utf8)
      })
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    await model.refresh()
    let original = try #require(model.resources.first { $0.name == "main.ts" })
    await model.select(original)
    #expect(model.content == "const answer: number = 42")
    phase2.close()
  }
}
