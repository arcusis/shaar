// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarApplicationModelTests {
  private func target(_ path: String = "/one") -> SiteControlTarget {
    SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com\(path)")!)
  }

  @Test func productionTransportDoesNotExposeFixtureData() async {
    let phase2 = ShaarPhase2Model(target: target(), transport: ShaarPhase2PendingTransport())
    phase2.open()
    for _ in 0..<20 { await Task.yield() }
    #expect(!phase2.available)
    do {
      _ = try await phase2.execute(.storageItems(local: true, skip: 0, count: 50))
      Issue.record("Production transport accepted a command without the capability")
    } catch {}
    phase2.close()
  }

  @Test func fixtureStorageCanFilterPageAndResetOnNavigation() async {
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .storageItems(_, let skip, _):
        if skip == 0 {
          return ["items": [["key": "theme", "value": "dark"]], "hasMore": true]
        }
        return ["items": [["key": "locale", "value": "en"]], "hasMore": false]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target(), transport: fixture)
    let model = ShaarApplicationModel(phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    #expect(phase2.available)
    model.selectArea(.local)
    await model.refresh()
    #expect(model.rows.map(\.name) == ["theme"])
    #expect(model.hasMore)
    await model.loadMore()
    #expect(model.rows.map(\.name) == ["theme", "locale"])
    model.search = "dark"
    #expect(model.visibleRows.map(\.name) == ["theme"])
    model.selectAdjacent(forward: true)
    #expect(model.selectedID == "theme")
    phase2.updateTarget(target("/two"), committed: true)
    model.reset()
    #expect(model.rows.isEmpty && model.search.isEmpty && model.selectedID == nil)
    #expect(!phase2.available)
    phase2.close()
  }

  @Test func indexedDBAndCacheCommandsUseSelectedPath() async {
    var commands: [ShaarDevToolsPhase2Command] = []
    let fixture = ShaarPhase2FixtureTransport { command in
      commands.append(command)
      switch command {
      case .indexedDBNames: return ["items": [["name": "notes"]]]
      case .indexedDBSchema: return ["items": [["name": "entries"]]]
      case .indexedDBData: return ["items": [["key": "1", "value": "A"]]]
      case .cacheNames: return ["items": [["cacheID": "cache-1", "name": "v1"]]]
      case .cacheEntries:
        return ["items": [["url": "https://example.com/app.js", "method": "GET", "status": 200]]]
      case .cacheResponse:
        return ["items": [], "body": "console.log('ok')", "base64Encoded": false]
      default: return ["items": []]
      }
    }
    let phase2 = ShaarPhase2Model(target: target(), transport: fixture)
    let model = ShaarApplicationModel(phase2: phase2)
    phase2.open()
    for _ in 0..<20 where !phase2.available { await Task.yield() }
    model.selectArea(.indexedDB)
    await model.refresh()
    model.selectDatabase("notes")
    await model.refresh()
    model.selectStore("entries")
    await model.refresh()
    #expect(model.rows.first?.value == "A")
    model.selectArea(.cache)
    await model.refresh()
    model.selectCache("cache-1")
    await model.refresh()
    model.selectCacheEntry("https://example.com/app.js")
    await model.refresh()
    #expect(model.body == "console.log('ok')")
    #expect(
      commands.contains(.indexedDBData(database: "notes", store: "entries", skip: 0, count: 50)))
    #expect(
      commands.contains(
        .cacheResponse(cacheID: "cache-1", requestURL: "https://example.com/app.js")))
    phase2.close()
  }
}
