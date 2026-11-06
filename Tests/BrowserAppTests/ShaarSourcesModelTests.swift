// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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
    for _ in 0..<20 where !phase2.available { await Task.yield() }
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
    for _ in 0..<20 where !phase2.available { await Task.yield() }
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
    let model = ShaarSourcesModel(phase2: phase2) { url in
      if url.path.hasSuffix("com.chrome.devtools.json") {
        return Data(#"{"workspace":{"root":"\#(root.path)"}}"#.utf8)
      }
      return Data(#"{"version":3,"sources":["webpack://_N_E/./src/app.ts"]}"#.utf8)
    }
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    await model.refresh()
    await model.findLocalFiles(framework: .nextJS)
    #expect(model.localFiles.map(\.path) == [file.path])
    #expect(model.sourceFailure == nil)
    phase2.close()
  }
}
