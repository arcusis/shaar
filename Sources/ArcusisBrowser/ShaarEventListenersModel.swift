// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

struct ShaarEventListener: Identifiable, Equatable {
  let id: String
  let type: String
  let nodeID: Int
  let onAncestor: Bool
  let capture: Bool
  var passive: Bool
  var once: Bool
  let source: String?
  var nodeObjectID: String?
  var handlerObjectID: String?
}

struct ShaarEventListenerGroup: Identifiable, Equatable {
  let type: String
  let rows: [ShaarEventListener]
  var id: String { type }
}

enum ShaarEventListenerAncestors {
  static func chain(from nodeID: Int?, nodes: [Int: ShaarDOMNode]) -> [Int] {
    guard let nodeID else { return [] }
    var result: [Int] = []
    var current = nodes[nodeID]?.parentID
    while let parent = current, result.count < 32 {
      result.append(parent)
      current = nodes[parent]?.parentID
    }
    return result
  }
}

enum ShaarEventListenerGrouping {
  static func groups(_ listeners: [ShaarEventListener], includeAncestors: Bool)
    -> [ShaarEventListenerGroup]
  {
    let shown = listeners.filter { includeAncestors || !$0.onAncestor }
    return Set(shown.map(\.type)).sorted().map { type in
      ShaarEventListenerGroup(type: type, rows: shown.filter { $0.type == type })
    }
  }
}

enum ShaarEventListenerSource {
  static func label(url: String?, scriptID: String?, line: Int?, column: Int?) -> String? {
    guard let line, (0..<10_000_000).contains(line) else { return nil }
    let position = columnText(column, line: line)
    if let name = fileName(url) { return "\(name):\(position)" }
    if let scriptID, !scriptID.isEmpty, scriptID.utf8.count <= 64 {
      return "script \(scriptID):\(position)"
    }
    return position
  }

  private static func columnText(_ column: Int?, line: Int) -> String {
    guard let column, (0..<10_000_000).contains(column) else { return "\(line + 1)" }
    return "\(line + 1):\(column + 1)"
  }

  private static func fileName(_ url: String?) -> String? {
    guard let url, let parsed = URL(string: url) else { return nil }
    let name = parsed.lastPathComponent
    guard !name.isEmpty, name != "/" else { return nil }
    return name
  }
}

enum ShaarEventListenerDecoding {
  static func listeners(
    from payload: [String: Any], nodeID: Int, onAncestor: Bool, nodeObjectID: String?
  ) -> [ShaarEventListener] {
    return rows(from: payload).prefix(200).enumerated().compactMap { index, row in
      listener(
        row, index: index, nodeID: nodeID, onAncestor: onAncestor, nodeObjectID: nodeObjectID)
    }
  }

  private static func rows(from payload: [String: Any]) -> [[String: Any]] {
    if let rows = payload["listeners"] as? [[String: Any]] { return rows }
    guard let rows = payload["listeners"] as? [Any] else { return [] }
    return rows.compactMap { $0 as? [String: Any] }
  }

  private static func listener(
    _ row: [String: Any], index: Int, nodeID: Int, onAncestor: Bool, nodeObjectID: String?
  ) -> ShaarEventListener? {
    guard let type = row["type"] as? String, !type.isEmpty, type.utf8.count <= 256,
      let capture = bool(row["useCapture"]),
      let passive = bool(row["passive"]),
      let once = bool(row["once"])
    else { return nil }
    let handler = row["handler"] as? [String: Any]
    let handlerObjectID = handler?["objectId"] as? String
    let source = ShaarEventListenerSource.label(
      url: row["url"] as? String,
      scriptID: scriptID(row["scriptId"]),
      line: integer(row["lineNumber"]),
      column: integer(row["columnNumber"]))
    return ShaarEventListener(
      id: "\(nodeID)|\(type)|\(index)",
      type: type, nodeID: nodeID, onAncestor: onAncestor, capture: capture,
      passive: passive, once: once, source: source,
      nodeObjectID: nodeObjectID, handlerObjectID: handlerObjectID)
  }

  private static func scriptID(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = integer(value) { return String(value) }
    return nil
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    if let value = value as? Int { return value }
    if let value = value as? Double, value.rounded() == value { return Int(value) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }
}

@MainActor protocol ShaarEventListenersTransport {
  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws
  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws
}

struct ShaarEventListenersUnavailable: LocalizedError {
  var errorDescription: String? { ShellL10n.string("Event listeners need engine support") }
}

struct ShaarEventListenersPendingTransport: ShaarEventListenersTransport {
  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    []
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {
    throw ShaarEventListenersUnavailable()
  }

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }
}

@MainActor @Observable
final class ShaarEventListenersModel {
  private(set) var target: SiteControlTarget
  private(set) var nodeID: Int?
  private(set) var ancestors: [Int] = []
  private(set) var listeners: [ShaarEventListener] = []
  private(set) var loading = false
  var includeAncestors = true
  var failure: String?
  @ObservationIgnored private let transport: any ShaarEventListenersTransport
  @ObservationIgnored private var generation = 0

  init(target: SiteControlTarget, transport: any ShaarEventListenersTransport) {
    self.target = target
    self.transport = transport
  }

  var visibleGroups: [ShaarEventListenerGroup] {
    ShaarEventListenerGrouping.groups(listeners, includeAncestors: includeAncestors)
  }

  func updateTarget(_ target: SiteControlTarget) {
    guard self.target != target else { return }
    self.target = target
    generation += 1
    clear()
  }

  func refresh() async {
    await load(nodeID: nodeID, ancestors: ancestors)
  }

  func load(nodeID: Int?, ancestors: [Int]) async {
    generation += 1
    let generation = generation
    let target = target
    let chain = Array(ancestors.prefix(32))
    guard let nodeID else {
      clear()
      return
    }
    self.nodeID = nodeID
    self.ancestors = chain
    if listeners.isEmpty { loading = true }
    failure = nil
    do {
      let found = try await transport.listeners(
        nodeID: nodeID, ancestors: chain, target: target)
      guard generation == self.generation, self.target == target else { return }
      listeners = found
    } catch {
      guard generation == self.generation else { return }
      listeners = []
      failure = error.localizedDescription
    }
    if generation == self.generation { loading = false }
  }

  func remove(_ id: String) async {
    guard let listener = listeners.first(where: { $0.id == id }) else { return }
    let generation = generation
    do {
      try await transport.remove(listener, target: target)
      guard generation == self.generation else { return }
      listeners.removeAll { $0.id == id }
      failure = nil
    } catch {
      guard generation == self.generation else { return }
      failure = error.localizedDescription
    }
  }

  func togglePassive(_ id: String) async { await toggle(id, passive: true, once: false) }

  func toggleOnce(_ id: String) async { await toggle(id, passive: false, once: true) }

  private func toggle(_ id: String, passive: Bool, once: Bool) async {
    guard let index = listeners.firstIndex(where: { $0.id == id }) else { return }
    let listener = listeners[index]
    let generation = generation
    do {
      if passive {
        try await transport.setPassive(listener, passive: !listener.passive, target: target)
      } else {
        try await transport.setOnce(listener, once: !listener.once, target: target)
      }
      guard generation == self.generation, listeners.indices.contains(index),
        listeners[index].id == id
      else { return }
      if passive { listeners[index].passive.toggle() } else { listeners[index].once.toggle() }
      failure = nil
    } catch {
      guard generation == self.generation else { return }
      failure = error.localizedDescription
    }
  }

  private func clear() {
    nodeID = nil
    ancestors = []
    listeners = []
    loading = false
    failure = nil
  }
}
