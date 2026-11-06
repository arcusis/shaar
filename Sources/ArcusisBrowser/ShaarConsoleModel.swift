// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

struct ShaarConsoleRow: Identifiable, Equatable {
  let event: ShaarConsoleEvent
  var count: Int
  var id: UUID { event.id }
}

@MainActor @Observable
final class ShaarConsoleModel {
  var level: ShaarConsoleEvent.Level?
  var origin: ShaarConsoleEvent.Origin?
  var search = ""
  var selectedID: UUID?
  var command = ""
  private(set) var busy = false
  private(set) var localEntries: [ShaarConsoleEvent] = []
  private(set) var history: [String] = []
  private(set) var expanded: Set<UUID> = []
  private(set) var properties: [UUID: [ShaarConsoleProperty]] = [:]
  private(set) var propertyFailures: [UUID: String] = [:]
  @ObservationIgnored private var historyIndex: Int?
  @ObservationIgnored private var revision = 0

  func rows(from events: [ShaarDevToolsEvent]) -> [ShaarConsoleRow] {
    let entries =
      events.compactMap { event -> ShaarConsoleEvent? in
        if case .console(let value) = event { return value }
        return nil
      } + localEntries
    var result: [ShaarConsoleRow] = []
    for entry in entries where matches(entry) {
      if let last = result.last, repeatKey(last.event) == repeatKey(entry) {
        result[result.count - 1].count += 1
      } else {
        result.append(ShaarConsoleRow(event: entry, count: 1))
      }
    }
    return result
  }

  func clearEntries() {
    revision += 1
    localEntries.removeAll()
    selectedID = nil
    expanded.removeAll()
    properties.removeAll()
    propertyFailures.removeAll()
  }

  func historyCommand(up: Bool) -> String? {
    guard !history.isEmpty else { return nil }
    let current = historyIndex ?? history.count
    historyIndex = up ? max(0, current - 1) : min(history.count, current + 1)
    guard let historyIndex, historyIndex < history.count else { return "" }
    return history[historyIndex]
  }

  func submit(evaluate: @MainActor (String) async throws -> String) async {
    let expression = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, !expression.isEmpty else { return }
    command = ""
    history.append(expression)
    if history.count > 100 { history.removeFirst() }
    historyIndex = nil
    localEntries.append(.init(id: UUID(), level: .log, message: "> \(expression)", source: nil))
    busy = true
    defer { busy = false }
    do {
      let output = try await evaluate(expression)
      localEntries.append(.init(id: UUID(), level: .info, message: output, source: nil))
    } catch {
      localEntries.append(
        .init(id: UUID(), level: .error, message: error.localizedDescription, source: nil))
    }
    if localEntries.count > 500 { localEntries.removeFirst(localEntries.count - 500) }
  }

  func toggleProperties(for event: ShaarConsoleEvent, inspector: InspectorModel?) async {
    if expanded.contains(event.id) {
      expanded.remove(event.id)
      return
    }
    expanded.insert(event.id)
    if !event.previewProperties.isEmpty {
      properties[event.id] = event.previewProperties
      return
    }
    guard let inspector, let objectID = event.objectID else { return }
    let currentRevision = revision
    do {
      let reply = try await inspector.call(
        "Runtime.getProperties", params: ["objectId": objectID, "ownProperties": true])
      guard currentRevision == revision else { return }
      properties[event.id] = Self.parseProperties(reply)
      propertyFailures[event.id] = nil
    } catch {
      guard currentRevision == revision else { return }
      propertyFailures[event.id] = error.localizedDescription
    }
  }

  static func parseProperties(_ reply: [String: Any]) -> [ShaarConsoleProperty] {
    let rows = reply["result"] as? [[String: Any]] ?? []
    return rows.prefix(80).compactMap { row in
      guard let name = row["name"] as? String, name.count <= 128,
        let value = row["value"] as? [String: Any]
      else { return nil }
      let description =
        value["description"] as? String
        ?? value["value"].map { String(describing: $0) } ?? "undefined"
      return ShaarConsoleProperty(name: name, value: String(description.prefix(1_024)))
    }
  }

  func agentCopyText(for row: ShaarConsoleRow) -> String {
    var lines = [
      "\(row.event.origin.rawValue) console \(row.event.level.rawValue): \(row.event.message)"
    ]
    if row.count > 1 { lines.append("Repeated \(row.count) times") }
    if let source = row.event.source { lines.append("Source: \(source)") }
    for frame in row.event.stack.prefix(20) {
      lines.append("at \(frame.function) (\(frame.source))")
    }
    for property in properties[row.id] ?? row.event.previewProperties {
      lines.append("\(property.name): \(property.value)")
    }
    return String(lines.joined(separator: "\n").prefix(16_384))
  }

  private func matches(_ event: ShaarConsoleEvent) -> Bool {
    guard origin == nil || origin == event.origin else { return false }
    guard level == nil || level == event.level else { return false }
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    return event.origin.rawValue.localizedStandardContains(needle)
      || event.message.localizedStandardContains(needle)
      || event.source?.localizedStandardContains(needle) == true
      || event.stack.contains { $0.source.localizedStandardContains(needle) }
  }

  private func repeatKey(_ event: ShaarConsoleEvent) -> String {
    "\(event.origin.rawValue)\u{0}\(event.level.rawValue)\u{0}\(event.message)\u{0}\(event.source ?? "")"
  }
}
