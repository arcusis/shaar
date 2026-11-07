// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

enum ShaarApplicationArea: String, CaseIterable {
  case cookies = "Cookies"
  case local = "Local Storage"
  case session = "Session Storage"
  case indexedDB = "IndexedDB"
  case cache = "Cache Storage"
  case workers = "Service Workers"

  var symbol: String {
    switch self {
    case .cookies: "circle.grid.2x2"
    case .local: "externaldrive"
    case .session: "rectangle.stack"
    case .indexedDB: "cylinder.split.1x2"
    case .cache: "archivebox"
    case .workers: "gearshape.2"
    }
  }
}

struct ShaarApplicationRow: Identifiable, Equatable {
  let id: String
  let name: String
  let value: String
  let detail: String
}

struct ShaarApplicationWorker: Identifiable, Equatable {
  let id: String
  var scopeURL: String
  var scriptURL: String
  var status: String
}

@MainActor @Observable
final class ShaarApplicationModel {
  var area = ShaarApplicationArea.cookies
  var search = ""
  private(set) var rows: [ShaarApplicationRow] = []
  private(set) var workers: [ShaarApplicationWorker] = []
  private(set) var body: String?
  private(set) var bodyEncoded = false
  private(set) var hasMore = false
  private(set) var loading = false
  var failure: String?
  var selectedID: String?
  var database: String?
  var store: String?
  var cacheID: String?
  var cacheEntryURL: String?
  @ObservationIgnored private let phase2: ShaarPhase2Model
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var lastSequence: UInt64 = 0

  init(phase2: ShaarPhase2Model) { self.phase2 = phase2 }

  var selectionKey: String {
    [area.rawValue, database ?? "", store ?? "", cacheID ?? "", cacheEntryURL ?? ""]
      .joined(separator: "\u{0}")
  }

  var isStorage: Bool { area == .local || area == .session }
  var localStorage: Bool { area == .local }
  var visibleRows: [ShaarApplicationRow] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return rows }
    return rows.filter {
      $0.name.localizedStandardContains(needle) || $0.value.localizedStandardContains(needle)
        || $0.detail.localizedStandardContains(needle)
    }
  }

  func selectAdjacent(forward: Bool, from focusedID: String? = nil) {
    let visible = visibleRows
    guard !visible.isEmpty else {
      selectedID = nil
      return
    }
    let currentID = focusedID ?? selectedID
    let index = visible.firstIndex { $0.id == currentID }
    let next =
      index.flatMap {
        ShaarDevToolsNavigation.adjacentIndex($0, count: visible.count, forward: forward)
      } ?? 0
    selectedID = visible[next].id
  }

  func reset() {
    revision += 1
    lastSequence = 0
    rows.removeAll()
    workers.removeAll()
    body = nil
    bodyEncoded = false
    hasMore = false
    selectedID = nil
    search = ""
    database = nil
    store = nil
    cacheID = nil
    cacheEntryURL = nil
    loading = false
    failure = nil
  }

  func selectArea(_ value: ShaarApplicationArea) {
    guard area != value else { return }
    area = value
    search = ""
    clearPath()
  }

  func selectDatabase(_ name: String) {
    database = name
    store = nil
    clearRows()
  }

  func selectStore(_ name: String) {
    store = name
    clearRows()
  }

  func selectCache(_ id: String) {
    cacheID = id
    cacheEntryURL = nil
    clearRows()
  }

  func selectCacheEntry(_ url: String) {
    cacheEntryURL = url
    clearRows()
  }

  func back() {
    if cacheEntryURL != nil {
      cacheEntryURL = nil
    } else if cacheID != nil {
      cacheID = nil
    } else if store != nil {
      store = nil
    } else {
      database = nil
    }
    clearRows()
  }

  func refresh() async {
    clearRows()
    guard phase2.available else { return }
    guard let command = command(skip: 0) else {
      if area == .workers { rebuildWorkers() }
      return
    }
    await load(command, append: false)
  }

  func loadMore() async {
    guard hasMore, let command = command(skip: rows.count) else { return }
    await load(command, append: true)
  }

  func saveStorage(key: String, value: String) async {
    guard isStorage else { return }
    await mutate(.storageSet(local: localStorage, key: key, value: value))
  }

  func removeStorage(key: String) async {
    guard isStorage else { return }
    await mutate(.storageRemove(local: localStorage, key: key))
  }

  func clearStorage() async {
    guard isStorage else { return }
    await mutate(.storageClear(local: localStorage))
  }

  func updateWorker(_ worker: ShaarApplicationWorker) async {
    await mutate(.serviceWorkerUpdate(scopeURL: worker.scopeURL))
  }

  func unregisterWorker(_ worker: ShaarApplicationWorker) async {
    await mutate(.serviceWorkerUnregister(scopeURL: worker.scopeURL))
  }

  func receive(_ events: [ShaarDevToolsPhase2Event]) {
    for event in events where event.sequence > lastSequence {
      lastSequence = event.sequence
      switch event.id {
      case .storageAdded, .storageUpdated:
        guard isStorage, event.localStorage == localStorage,
          let key = event.text["key"], let value = event.text["value"]
        else { continue }
        let row = ShaarApplicationRow(id: key, name: key, value: value, detail: "")
        if let index = rows.firstIndex(where: { $0.id == key }) {
          rows[index] = row
        } else {
          rows.append(row)
        }
      case .storageRemoved:
        guard isStorage, event.localStorage == localStorage,
          let key = event.text["key"]
        else { continue }
        rows.removeAll { $0.id == key }
      case .storageCleared:
        if isStorage, event.localStorage == localStorage { rows.removeAll() }
      case .workerRegistration, .workerVersion:
        receiveWorker(event)
      case .workerError:
        failure = event.text["text"]
      case .timeline: break
      }
    }
  }

  private func rebuildWorkers() {
    workers.removeAll()
    for event in phase2.events {
      switch event.id {
      case .workerRegistration, .workerVersion:
        receiveWorker(event)
      case .workerError:
        failure = event.text["text"]
      default:
        break
      }
    }
  }

  private func assignBody(_ reply: ShaarDevToolsPhase2Reply) {
    if let text = Self.readableText(reply) {
      body = text
      bodyEncoded = false
      return
    }
    body = reply.body
    bodyEncoded = reply.base64Encoded == true
  }

  private static func readableText(_ reply: ShaarDevToolsPhase2Reply) -> String? {
    guard reply.base64Encoded == true, let encoded = reply.body,
      let data = Data(base64Encoded: encoded), !data.contains(0)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func receiveWorker(_ event: ShaarDevToolsPhase2Event) {
    for item in event.items {
      guard let id = item.text["registrationID"] else { continue }
      if item.flag["deleted"] == true {
        workers.removeAll { $0.id == id }
        continue
      }
      let index = workers.firstIndex { $0.id == id }
      var worker =
        index.map { workers[$0] }
        ?? ShaarApplicationWorker(id: id, scopeURL: "", scriptURL: "", status: "")
      if let scope = item.text["scopeURL"] { worker.scopeURL = scope }
      if let script = item.text["scriptURL"] { worker.scriptURL = script }
      if let status = item.text["status"] { worker.status = status }
      if let index { workers[index] = worker } else { workers.append(worker) }
    }
  }

  private func command(skip: Int) -> ShaarDevToolsPhase2Command? {
    switch area {
    case .cookies, .workers: return nil
    case .local: return .storageItems(local: true, skip: skip, count: 50)
    case .session: return .storageItems(local: false, skip: skip, count: 50)
    case .indexedDB:
      if let database, let store {
        return .indexedDBData(
          database: database, store: store, skip: skip, count: 50)
      }
      if let database { return .indexedDBSchema(database: database) }
      return .indexedDBNames
    case .cache:
      if let cacheID, let cacheEntryURL {
        return .cacheResponse(cacheID: cacheID, requestURL: cacheEntryURL)
      }
      if let cacheID { return .cacheEntries(cacheID: cacheID, skip: skip, count: 50) }
      return .cacheNames
    }
  }

  private func load(_ command: ShaarDevToolsPhase2Command, append: Bool) async {
    if append && loading { return }
    let revision = revision
    let key = selectionKey
    loading = true
    defer {
      if revision == self.revision { loading = false }
    }
    do {
      let reply = try await phase2.execute(command)
      guard revision == self.revision, key == selectionKey else { return }
      let incoming = reply.items.compactMap(row)
      if append { rows += incoming } else { rows = incoming }
      assignBody(reply)
      hasMore = reply.hasMore == true
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      guard revision == self.revision, key == selectionKey else { return }
      failure = error.localizedDescription
    }
  }

  private func row(_ item: ShaarDevToolsPhase2Item) -> ShaarApplicationRow? {
    let name = item.text["key"] ?? item.text["name"] ?? item.text["url"]
    guard let name else { return nil }
    let id = item.text["cacheID"] ?? name
    let value = item.text["value"] ?? item.text["primaryKey"] ?? ""
    let status = item.number["status"].map { String(Int($0)) } ?? ""
    let detail = [item.text["method"] ?? "", status].filter { !$0.isEmpty }.joined(separator: " · ")
    return ShaarApplicationRow(id: id, name: name, value: value, detail: detail)
  }

  private func mutate(_ command: ShaarDevToolsPhase2Command) async {
    do {
      _ = try await phase2.execute(command)
      await refresh()
    } catch is CancellationError {
      return
    } catch {
      failure = error.localizedDescription
    }
  }

  private func clearPath() {
    database = nil
    store = nil
    cacheID = nil
    cacheEntryURL = nil
    clearRows()
  }

  private func clearRows() {
    revision += 1
    rows.removeAll()
    body = nil
    bodyEncoded = false
    hasMore = false
    selectedID = nil
    failure = nil
  }
}
