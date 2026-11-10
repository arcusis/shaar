// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

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
    #expect(await phase2.waitUntilAvailable())
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
    #expect(await phase2.waitUntilAvailable())
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

  @Test func storageEditsUseTheSelectedArea() async {
    var commands: [ShaarDevToolsPhase2Command] = []
    let fixture = ShaarPhase2FixtureTransport { command in
      commands.append(command)
      if case .storageItems = command {
        return ["items": [["key": "inspector-key", "value": "original"]]]
      }
      return ["items": []]
    }
    let phase2 = ShaarPhase2Model(target: target(), transport: fixture)
    let model = ShaarApplicationModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    model.selectArea(.local)
    await model.refresh()
    await model.saveStorage(key: "shaar-probe", value: "edited")
    await model.removeStorage(key: "shaar-probe")
    model.selectArea(.session)
    await model.clearStorage()
    #expect(commands.contains(.storageSet(local: true, key: "shaar-probe", value: "edited")))
    #expect(commands.contains(.storageRemove(local: true, key: "shaar-probe")))
    #expect(commands.contains(.storageClear(local: false)))
    phase2.close()
  }

  @Test func cacheTextIsShownAndBinaryStaysEncoded() async {
    let text = Data("shaar-cached-body".utf8).base64EncodedString()
    let binary = Data([0x00, 0xFF, 0xFE]).base64EncodedString()
    let bodies = CacheBodies(text)
    let fixture = ShaarPhase2FixtureTransport { command in
      guard case .cacheResponse = command else {
        return ["items": [["cacheID": "cache-1", "name": "shaar-app"]]]
      }
      return ["items": [], "body": bodies.current, "base64Encoded": true]
    }
    let phase2 = ShaarPhase2Model(target: target(), transport: fixture)
    let model = ShaarApplicationModel(phase2: phase2)
    phase2.open()
    #expect(await phase2.waitUntilAvailable())
    model.selectArea(.cache)
    await model.refresh()
    model.selectCache("cache-1")
    model.selectCacheEntry("https://example.com/inspector-cached.txt")
    await model.refresh()
    #expect(model.body == "shaar-cached-body")
    #expect(!model.bodyEncoded)
    bodies.current = binary
    await model.refresh()
    #expect(model.body == binary)
    #expect(model.bodyEncoded)
    phase2.close()
  }

  @Test func workerListKeepsRegistrationsThatArriveBeforeCapability() async {
    let phase2 = ShaarPhase2Model(target: target(), transport: EarlyWorkerTransport())
    let model = ShaarApplicationModel(phase2: phase2)
    phase2.open()
    for _ in 0..<30 where !phase2.available { await Task.yield() }
    #expect(phase2.events.count == 2)
    model.selectArea(.workers)
    await model.refresh()
    #expect(model.workers.map(\.scopeURL) == ["https://example.com/"])
    #expect(model.workers.first?.scriptURL == "https://example.com/inspector-sw.js")
    #expect(model.workers.first?.status == "activated")
    phase2.close()
  }
}

@MainActor private final class CacheBodies {
  var current: String
  init(_ current: String) { self.current = current }
}

@MainActor private struct EarlyWorkerTransport: ShaarPhase2Transport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message> {
    AsyncStream { continuation in
      continuation.yield(.event(ApplicationWorkerFixtures.registration))
      continuation.yield(.event(ApplicationWorkerFixtures.version))
      continuation.yield(.available)
      continuation.finish()
    }
  }

  func execute(_ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget) async throws
    -> ShaarDevToolsPhase2Reply
  {
    throw CancellationError()
  }
}

@MainActor enum ApplicationWorkerFixtures {
  static let registration = ShaarDevToolsPhase2Event(
    sequence: 1, leaseID: 1, id: .workerRegistration, localStorage: nil,
    text: [:], number: [:], flag: [:],
    items: [
      ShaarDevToolsPhase2Item(
        text: ["registrationID": "reg-1", "scopeURL": "https://example.com/"],
        number: [:], flag: [:])
    ],
    truncated: false)
  static let version = ShaarDevToolsPhase2Event(
    sequence: 2, leaseID: 1, id: .workerVersion, localStorage: nil,
    text: [:], number: [:], flag: [:],
    items: [
      ShaarDevToolsPhase2Item(
        text: [
          "registrationID": "reg-1",
          "scriptURL": "https://example.com/inspector-sw.js",
          "status": "activated",
        ],
        number: [:], flag: [:])
    ],
    truncated: false)
}
