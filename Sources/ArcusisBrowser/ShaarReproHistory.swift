// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@MainActor final class ShaarReproHistory {
  struct Snapshot {
    let console: [ShaarConsoleEvent]
    let network: [ShaarNetworkEvent]
  }

  private struct Entry {
    let receivedAt: Date
    let event: ShaarDevToolsEvent
    let bytes: Int
  }

  private let maxAge: TimeInterval = 30
  private let maxCount = 2_000
  private let maxBytes = 2 * 1024 * 1024
  private let maxEventBytes = 16 * 1024
  private var target: SiteControlTarget?
  private var entries: [Entry] = []
  private var bytes = 0

  var isActive: Bool { target != nil }

  func start(for target: SiteControlTarget) {
    clear()
    self.target = target
  }

  func stop() {
    clear()
    target = nil
  }

  func clear() {
    entries.removeAll()
    bytes = 0
  }

  func record(_ event: ShaarDevToolsEvent, for target: SiteControlTarget, at now: Date = Date()) {
    guard self.target == target else { return }
    let stored = metadataOnly(event)
    let size = byteCount(stored)
    guard size <= maxEventBytes else { return }
    entries.append(Entry(receivedAt: now, event: stored, bytes: size))
    bytes += size
    prune(at: now)
  }

  func snapshot(at now: Date = Date()) -> Snapshot {
    prune(at: now)
    var console: [ShaarConsoleEvent] = []
    var network: [ShaarNetworkEvent] = []
    for entry in entries {
      switch entry.event {
      case .console(let value): console.append(value)
      case .network(let value): network.append(value)
      }
    }
    return Snapshot(console: console, network: network)
  }

  private func prune(at now: Date) {
    while let first = entries.first,
      first.receivedAt < now.addingTimeInterval(-maxAge)
        || entries.count > maxCount || bytes > maxBytes
    {
      bytes -= first.bytes
      entries.removeFirst()
    }
  }

  private func metadataOnly(_ event: ShaarDevToolsEvent) -> ShaarDevToolsEvent {
    switch event {
    case .console(let value):
      return .console(
        ShaarConsoleEvent(
          id: value.id, level: value.level, message: value.message, source: value.source,
          origin: value.origin, timestamp: value.timestamp))
    case .network(let value):
      return .network(
        ShaarNetworkEvent(
          id: value.id, method: value.method, url: value.url, status: value.status,
          requestID: value.requestID, phase: value.phase, mimeType: value.mimeType,
          encodedBytes: value.encodedBytes, time: value.time, failure: value.failure,
          requestHeaders: Array(value.requestHeaders.prefix(24)),
          responseHeaders: Array(value.responseHeaders.prefix(24))))
    }
  }

  private func byteCount(_ event: ShaarDevToolsEvent) -> Int {
    switch event {
    case .console(let value):
      return 64 + value.message.utf8.count + (value.source?.utf8.count ?? 0)
    case .network(let value):
      let headers = (value.requestHeaders + value.responseHeaders).reduce(0) {
        $0 + $1.name.utf8.count + $1.value.utf8.count
      }
      return 128 + value.url.utf8.count + value.method.utf8.count + headers
    }
  }
}
