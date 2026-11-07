// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

struct ShaarConsoleRow: Identifiable, Equatable, Sendable {
  let event: ShaarConsoleEvent
  var count: Int
  var id: UUID { event.id }
}

struct ShaarConsoleEvaluation: Equatable, Sendable {
  var message: String
  var objectID: String?
  var previewProperties: [ShaarConsoleProperty]
}

struct ShaarConsoleEvaluationError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

@MainActor @Observable
final class ShaarConsoleModel {
  static let objectGroup = "shaar-console"

  var level: ShaarConsoleEvent.Level?
  var origin: ShaarConsoleEvent.Origin?
  var search = ""
  var searchUsesRegex = false
  var preserveLog = false
  var selectedID: UUID?
  var command = ""
  private(set) var busy = false
  private(set) var localEntries: [ShaarConsoleEvent] = []
  private(set) var history: [String] = []
  private(set) var expanded: Set<UUID> = []
  private(set) var properties: [UUID: [ShaarConsoleProperty]] = [:]
  private(set) var propertyFailures: [UUID: String] = [:]
  private(set) var childProperties: [String: [ShaarConsoleProperty]] = [:]
  private(set) var expandedChildren: Set<String> = []
  let projection = ShaarDevToolsListProjection<[ShaarConsoleRow]>()
  @ObservationIgnored var onClear: (@MainActor () -> Void)?
  @ObservationIgnored private var historyIndex: Int?
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var lastEvents: [ShaarDevToolsEvent] = []
  @ObservationIgnored var loadProperties:
    (@MainActor (String) async throws -> [ShaarConsoleProperty])?

  var regexIsInvalid: Bool {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard searchUsesRegex, !needle.isEmpty else { return false }
    return Self.compiledExpression(needle, usesRegex: true) == nil
  }

  func rows(from events: [ShaarDevToolsEvent]) -> [ShaarConsoleRow] {
    Self.projectRows(
      events, localEntries: localEntries, level: level, origin: origin, search: search,
      searchUsesRegex: searchUsesRegex)
  }

  func scheduleRows(from events: [ShaarDevToolsEvent]) {
    lastEvents = events
    let localEntries = localEntries
    let level = level
    let origin = origin
    let search = search
    let searchUsesRegex = searchUsesRegex
    projection.schedule {
      Self.projectRows(
        events, localEntries: localEntries, level: level, origin: origin, search: search,
        searchUsesRegex: searchUsesRegex)
    }
  }

  nonisolated private static func projectRows(
    _ events: [ShaarDevToolsEvent], localEntries: [ShaarConsoleEvent],
    level: ShaarConsoleEvent.Level?, origin: ShaarConsoleEvent.Origin?, search: String,
    searchUsesRegex: Bool
  ) -> [ShaarConsoleRow] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let expression = compiledExpression(needle, usesRegex: searchUsesRegex)
    if searchUsesRegex && !needle.isEmpty && expression == nil { return [] }
    var seen: Set<UUID> = []
    var entries: [ShaarConsoleEvent] = []
    for entry in consoleEntries(events) + localEntries where seen.insert(entry.id).inserted {
      entries.append(entry)
    }
    let orderedEntries = entries.sorted { $0.timestamp < $1.timestamp }
    var result: [ShaarConsoleRow] = []
    for entry in orderedEntries
    where matches(entry, level: level, origin: origin, search: needle, expression: expression) {
      if let last = result.last, repeatKey(last.event) == repeatKey(entry) {
        result[result.count - 1].count += 1
      } else {
        result.append(ShaarConsoleRow(event: entry, count: 1))
      }
    }
    return result
  }

  func retain(from events: [ShaarDevToolsEvent]) {
    var seen = Set(localEntries.map(\.id))
    for entry in Self.consoleEntries(events) where seen.insert(entry.id).inserted {
      localEntries.append(entry)
    }
    if localEntries.count > 500 { localEntries.removeFirst(localEntries.count - 500) }
    scheduleRows(from: lastEvents)
  }

  func clearEntries() {
    revision += 1
    projection.clear()
    lastEvents = []
    localEntries.removeAll()
    selectedID = nil
    expanded.removeAll()
    properties.removeAll()
    propertyFailures.removeAll()
    childProperties.removeAll()
    expandedChildren.removeAll()
    onClear?()
  }

  func selectAdjacent(in rows: [ShaarConsoleRow], forward: Bool, from focusedID: UUID? = nil) {
    guard !rows.isEmpty else { return }
    let currentID = focusedID ?? selectedID
    let current = rows.firstIndex { $0.id == currentID }
    let next =
      current.flatMap {
        ShaarDevToolsNavigation.adjacentIndex($0, count: rows.count, forward: forward)
      } ?? 0
    selectedID = rows[next].id
  }

  func historyCommand(up: Bool) -> String? {
    guard !history.isEmpty else { return nil }
    let current = historyIndex ?? history.count
    historyIndex = up ? max(0, current - 1) : min(history.count, current + 1)
    guard let historyIndex, historyIndex < history.count else { return "" }
    return history[historyIndex]
  }

  func submit(evaluate: @MainActor (String) async throws -> ShaarConsoleEvaluation) async {
    let expression = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, !expression.isEmpty else { return }
    command = ""
    history.append(expression)
    if history.count > 100 { history.removeFirst() }
    historyIndex = nil
    localEntries.append(.init(id: UUID(), level: .log, message: "> \(expression)", source: nil))
    scheduleRows(from: lastEvents)
    busy = true
    defer { busy = false }
    do {
      let output = try await evaluate(expression)
      localEntries.append(
        .init(
          id: UUID(), level: .info, message: output.message, source: nil,
          objectID: output.objectID, previewProperties: output.previewProperties))
    } catch {
      localEntries.append(
        .init(id: UUID(), level: .error, message: error.localizedDescription, source: nil))
    }
    if localEntries.count > 500 { localEntries.removeFirst(localEntries.count - 500) }
    scheduleRows(from: lastEvents)
  }

  func toggleProperties(for event: ShaarConsoleEvent, inspector: InspectorModel?) async {
    if expanded.contains(event.id) {
      expanded.remove(event.id)
      return
    }
    expanded.insert(event.id)
    if !event.usesPanelLease && !event.previewProperties.isEmpty {
      properties[event.id] = event.previewProperties
      return
    }
    guard let objectID = event.objectID else { return }
    let currentRevision = revision
    do {
      let loaded = try await propertiesForObject(
        objectID, usesPanelLease: event.usesPanelLease, inspector: inspector)
      guard currentRevision == revision else { return }
      properties[event.id] = loaded
      propertyFailures[event.id] = nil
    } catch {
      guard currentRevision == revision else { return }
      propertyFailures[event.id] = error.localizedDescription
    }
  }

  func toggleChild(
    _ property: ShaarConsoleProperty, in event: ShaarConsoleEvent,
    inspector: InspectorModel?
  ) async {
    guard let objectID = property.objectID else { return }
    if expandedChildren.contains(objectID) {
      expandedChildren.remove(objectID)
      return
    }
    expandedChildren.insert(objectID)
    if childProperties[objectID] != nil { return }
    let currentRevision = revision
    do {
      let loaded = try await propertiesForObject(
        objectID, usesPanelLease: event.usesPanelLease, inspector: inspector)
      guard currentRevision == revision else { return }
      childProperties[objectID] = loaded
    } catch {
      guard currentRevision == revision else { return }
      childProperties[objectID] = [
        ShaarConsoleProperty(name: "Error", value: error.localizedDescription)
      ]
    }
  }

  private func propertiesForObject(
    _ objectID: String, usesPanelLease: Bool,
    inspector: InspectorModel?
  ) async throws -> [ShaarConsoleProperty] {
    if usesPanelLease {
      guard let loadProperties else {
        throw ShaarConsoleEvaluationError(message: "Console object is unavailable.")
      }
      return try await loadProperties(objectID)
    }
    guard let inspector else { return [] }
    let reply = try await inspector.call(
      "Runtime.getProperties", params: ["objectId": objectID, "ownProperties": true])
    return Self.parseProperties(reply)
  }

  static func evaluation(from reply: [String: Any]) throws -> ShaarConsoleEvaluation {
    if let exception = reply["exceptionDetails"] as? [String: Any] {
      throw ShaarConsoleEvaluationError(message: exceptionMessage(exception))
    }
    guard let result = reply["result"] as? [String: Any] else {
      throw ShaarConsoleEvaluationError(message: "The page returned no result.")
    }
    if result["subtype"] as? String == "error" {
      throw ShaarConsoleEvaluationError(message: displayMessage(from: result))
    }
    return ShaarConsoleEvaluation(
      message: String(displayMessage(from: result).prefix(8_192)),
      objectID: result["objectId"] as? String,
      previewProperties: previewProperties(from: result))
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
      return ShaarConsoleProperty(
        name: name, value: String(description.prefix(1_024)),
        objectID: value["objectId"] as? String)
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

  nonisolated private static func consoleEntries(
    _ events: [ShaarDevToolsEvent]
  ) -> [ShaarConsoleEvent] {
    events.compactMap { event in
      if case .console(let value) = event { return value }
      return nil
    }
  }

  nonisolated private static func compiledExpression(
    _ needle: String, usesRegex: Bool
  ) -> NSRegularExpression? {
    guard usesRegex, !needle.isEmpty else { return nil }
    return try? NSRegularExpression(pattern: needle)
  }

  nonisolated private static func matches(
    _ event: ShaarConsoleEvent, level: ShaarConsoleEvent.Level?,
    origin: ShaarConsoleEvent.Origin?, search: String, expression: NSRegularExpression?
  ) -> Bool {
    guard origin == nil || origin == event.origin else { return false }
    guard level == nil || level == event.level else { return false }
    if let expression { return regexMatches(expression, event) }
    guard !search.isEmpty else { return true }
    return event.origin.rawValue.localizedStandardContains(search)
      || event.message.localizedStandardContains(search)
      || event.source?.localizedStandardContains(search) == true
      || event.stack.contains { $0.source.localizedStandardContains(search) }
  }

  nonisolated private static func regexMatches(
    _ expression: NSRegularExpression, _ event: ShaarConsoleEvent
  ) -> Bool {
    let fields =
      [event.message, event.source ?? "", event.origin.rawValue]
      + event.stack.map(\.source)
    return fields.contains { field in
      let range = NSRange(field.startIndex..<field.endIndex, in: field)
      return expression.firstMatch(in: field, range: range) != nil
    }
  }

  nonisolated private static func repeatKey(_ event: ShaarConsoleEvent) -> String {
    "\(event.origin.rawValue)\u{0}\(event.level.rawValue)\u{0}\(event.message)\u{0}\(event.source ?? "")"
  }

  private static func exceptionMessage(_ exception: [String: Any]) -> String {
    if let inner = exception["exception"] as? [String: Any],
      let description = inner["description"] as? String, !description.isEmpty
    {
      return description
    }
    if let text = exception["text"] as? String, !text.isEmpty { return text }
    return "The page script failed."
  }

  private static func displayMessage(from result: [String: Any]) -> String {
    if let value = result["value"] {
      if value is NSNull { return "null" }
      if let text = value as? String { return text }
      if let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      {
        return text
      }
      return String(describing: value)
    }
    if let description = result["description"] as? String { return description }
    return "undefined"
  }

  private static func previewProperties(from result: [String: Any]) -> [ShaarConsoleProperty] {
    guard let preview = result["preview"] as? [String: Any],
      let rows = preview["properties"] as? [[String: Any]]
    else { return [] }
    return rows.prefix(40).compactMap { row in
      guard let name = row["name"] as? String, !name.isEmpty else { return nil }
      let raw = (row["value"] as? String) ?? (row["type"] as? String) ?? ""
      return ShaarConsoleProperty(
        name: String(name.prefix(128)), value: String(raw.prefix(1_024)))
    }
  }
}
