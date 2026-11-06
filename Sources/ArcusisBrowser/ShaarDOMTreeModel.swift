// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

enum ShaarDOMCommand: Equatable {
  case document
  case children(Int)
  case search(String)
  case searchResults(String, Int)
  case discardSearch(String)
  case highlight(Int)
  case hideHighlight
  case setAttribute(Int, String, String)
  case removeAttribute(Int, String)
  case setText(Int, String)
  case setHTML(Int, String)
  case remove(Int)
  case move(Int, Int, Int?)
  case markUndo
  case undo
  case outerHTML(Int)
}

enum ShaarDOMMessage {
  case available
  case unavailable
  case event(ShaarDOMEvent)
}

@MainActor protocol ShaarDOMTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDOMMessage>
  func execute(_ command: ShaarDOMCommand, for target: SiteControlTarget) async throws -> [String:
    Any]
}

private struct ShaarDOMUnavailable: LocalizedError {
  var errorDescription: String? { ShellL10n.string("Live DOM tree is unavailable for this tab") }
}

private struct ShaarDOMFailure: LocalizedError {
  let errorDescription: String?
  init(_ key: String) { errorDescription = ShellL10n.string(key) }
}

struct ShaarDOMPendingTransport: ShaarDOMTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDOMMessage> {
    AsyncStream { continuation in
      continuation.yield(.unavailable)
      continuation.finish()
    }
  }

  func execute(_ command: ShaarDOMCommand, for target: SiteControlTarget) async throws -> [String:
    Any]
  {
    throw ShaarDOMUnavailable()
  }
}

struct ShaarDOMRow: Identifiable {
  let node: ShaarDOMNode
  let depth: Int
  var id: Int { node.id }
}

@MainActor @Observable
final class ShaarDOMTreeModel {
  private(set) var target: SiteControlTarget
  private(set) var available = false
  private(set) var loading = false
  private(set) var nodes: [Int: ShaarDOMNode] = [:]
  private(set) var rootID: Int?
  private(set) var matches: Set<Int> = []
  private(set) var selectedID: Int?
  private(set) var expanded: Set<Int> = []
  private(set) var canUndo = false
  var search = ""
  var failure: String?
  @ObservationIgnored private let transport: any ShaarDOMTransport
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var isOpen = false
  @ObservationIgnored private var lastSequence: UInt64 = 0
  @ObservationIgnored private var searchID: String?

  init(target: SiteControlTarget, transport: any ShaarDOMTransport) {
    self.target = target
    self.transport = transport
  }

  var selected: ShaarDOMNode? { selectedID.flatMap { nodes[$0] } }
  var rows: [ShaarDOMRow] {
    guard let rootID else { return [] }
    var result: [ShaarDOMRow] = []
    func append(_ id: Int, depth: Int) {
      guard depth <= 40, result.count < 10_000, let node = nodes[id] else { return }
      result.append(ShaarDOMRow(node: node, depth: depth))
      if expanded.contains(id) {
        for child in node.childrenIDs { append(child, depth: depth + 1) }
      }
    }
    append(rootID, depth: 0)
    return result
  }
  var breadcrumbs: [ShaarDOMNode] {
    guard let selectedID else { return [] }
    var path: [ShaarDOMNode] = []
    var id: Int? = selectedID
    while let current = id, let node = nodes[current], path.count < 40 {
      path.append(node)
      id = node.parentID
    }
    return path.reversed()
  }

  func selector(for id: Int) -> String {
    var parts: [String] = []
    var current: Int? = id
    while let value = current, let node = nodes[value], parts.count < 32 {
      if node.nodeType == 1 {
        let name = node.name.lowercased()
        let siblings = node.parentID.flatMap { nodes[$0]?.childrenIDs } ?? []
        let sameName = siblings.compactMap { nodes[$0] }.filter { $0.name == node.name }
        let index = sameName.firstIndex(where: { $0.id == value }).map { $0 + 1 } ?? 1
        parts.append("\(name):nth-of-type(\(index))")
      }
      current = node.parentID
    }
    return parts.reversed().joined(separator: " > ")
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    startStream()
  }

  func close() {
    generation += 1
    streamTask?.cancel()
    streamTask = nil
    isOpen = false
    reset()
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    generation += 1
    streamTask?.cancel()
    streamTask = nil
    reset()
    if isOpen { startStream() }
  }

  private func reset() {
    available = false
    loading = false
    nodes = [:]
    rootID = nil
    selectedID = nil
    expanded = []
    matches = []
    search = ""
    searchID = nil
    canUndo = false
    failure = nil
    lastSequence = 0
  }

  private func startStream() {
    let target = target
    let generation = generation
    streamTask = Task { [weak self, transport] in
      for await message in transport.messages(for: target) {
        guard let self, self.isOpen, self.target == target,
          self.generation == generation
        else { return }
        switch message {
        case .available:
          self.available = true
          await self.loadDocument()
        case .unavailable:
          self.reset()
        case .event(let event):
          await self.receive(event)
        }
      }
    }
  }

  func loadDocument() async {
    guard available else { return }
    let generation = generation
    let target = target
    loading = true
    defer { if self.generation == generation { loading = false } }
    do {
      let reply = try await transport.execute(.document, for: target)
      guard self.generation == generation, self.target == target else { return }
      guard let snapshot = ShaarDOMSnapshot.decode(reply) else {
        throw ShaarDOMFailure("DOM tree could not be read")
      }
      let previous = selectedID
      nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
      rootID = snapshot.rootID
      selectedID = previous.flatMap { nodes[$0] != nil ? $0 : nil }
      expanded.insert(snapshot.rootID)
      for node in snapshot.nodes where node.parentID == snapshot.rootID { expanded.insert(node.id) }
      failure = nil
    } catch {
      if self.generation == generation { failure = error.localizedDescription }
    }
  }

  func toggleExpanded(_ id: Int) async {
    guard let node = nodes[id], node.canExpand else { return }
    if expanded.contains(id) {
      expanded.remove(id)
      return
    }
    expanded.insert(id)
    if node.childrenIDs.isEmpty && node.childCount > 0 {
      do { _ = try await execute(.children(id)) } catch { failure = error.localizedDescription }
    }
  }

  func select(_ id: Int) {
    guard nodes[id] != nil else { return }
    selectedID = id
    var parent = nodes[id]?.parentID
    while let current = parent, let node = nodes[current] {
      expanded.insert(current)
      parent = node.parentID
    }
  }

  func performSearch() async {
    guard available else { return }
    if let searchID { _ = try? await execute(.discardSearch(searchID)) }
    searchID = nil
    matches = []
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    do {
      let result = try await execute(.search(String(query.prefix(512))))
      guard let id = result["searchId"] as? String,
        let count = result["resultCount"] as? Int,
        count >= 0, count <= 10_000
      else { throw ShaarDOMFailure("DOM search could not be completed") }
      searchID = id
      let found = try await execute(.searchResults(id, min(count, 500)))
      guard let ids = found["nodeIds"] as? [Int], ids.count <= 500 else {
        throw ShaarDOMFailure("DOM search could not be completed")
      }
      matches = Set(ids)
      if let first = ids.first { select(first) }
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  func highlight(_ id: Int?) async {
    guard available else { return }
    _ = try? await execute(id.map(ShaarDOMCommand.highlight) ?? .hideHighlight)
  }

  func setAttribute(_ name: String, value: String) async {
    guard let id = selectedID, !name.isEmpty, name.utf8.count <= 256,
      value.utf8.count <= 16_384
    else { return }
    await mutate(.setAttribute(id, name, value))
  }

  func removeAttribute(_ name: String) async {
    guard let id = selectedID else { return }
    await mutate(.removeAttribute(id, name))
  }

  func setText(_ value: String) async {
    guard let id = selectedID, value.utf8.count <= 16_384 else { return }
    await mutate(.setText(id, value))
  }

  func setHTML(_ value: String) async {
    guard let id = selectedID, value.utf8.count <= 262_144 else { return }
    await mutate(.setHTML(id, value))
  }

  func removeSelected() async {
    guard let id = selectedID else { return }
    await mutate(.remove(id))
    selectedID = nil
  }

  func move(_ id: Int, to parentID: Int, before siblingID: Int? = nil) async {
    guard id != parentID, nodes[id] != nil, nodes[parentID] != nil else { return }
    await mutate(.move(id, parentID, siblingID))
  }

  func toggleClass(_ className: String) async {
    guard let selected, !className.isEmpty else { return }
    var names =
      selected.attributes.first { $0.name == "class" }?
      .value.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    if names.contains(className) {
      names.removeAll { $0 == className }
    } else {
      names.append(className)
    }
    await setAttribute("class", value: names.joined(separator: " "))
  }

  func undo() async {
    guard canUndo else { return }
    do {
      _ = try await execute(.undo)
      await loadDocument()
      canUndo = false
    } catch { failure = error.localizedDescription }
  }

  func outerHTML(for id: Int) async -> String? {
    guard let result = try? await execute(.outerHTML(id)) else { return nil }
    return result["outerHTML"] as? String
  }

  private func mutate(_ command: ShaarDOMCommand) async {
    do {
      _ = try await execute(command)
      _ = try await execute(.markUndo)
      canUndo = true
      await loadDocument()
    } catch { failure = error.localizedDescription }
  }

  private func execute(_ command: ShaarDOMCommand) async throws -> [String: Any] {
    guard isOpen && available else { throw ShaarDOMUnavailable() }
    let target = target
    let generation = generation
    let result = try await transport.execute(command, for: target)
    guard isOpen, available, self.target == target, self.generation == generation else {
      throw CancellationError()
    }
    return result
  }

  private func receive(_ event: ShaarDOMEvent) async {
    guard available, event.sequence > lastSequence else { return }
    lastSequence = event.sequence
    if event.truncated {
      await loadDocument()
      return
    }
    switch event.mutation {
    case .documentUpdated:
      await loadDocument()
    case .childInserted(let parent, let previous, let node):
      guard var parentNode = nodes[parent] else {
        await loadDocument()
        return
      }
      var children = parentNode.childrenIDs
      if let index = children.firstIndex(of: previous) {
        children.insert(node.id, at: index + 1)
      } else {
        children.insert(node.id, at: 0)
      }
      parentNode = parentNode.replacing(childCount: children.count, childrenIDs: children)
      nodes[parent] = parentNode
      nodes[node.id] = node
    case .childRemoved(let parent, let nodeID):
      removeDescendants(of: nodeID)
      if let parentNode = nodes[parent] {
        let children = parentNode.childrenIDs.filter { $0 != nodeID }
        nodes[parent] = parentNode.replacing(childCount: children.count, childrenIDs: children)
      }
      if selectedID == nodeID { selectedID = nil }
    case .childrenSet(let parent, let children):
      guard let parentNode = nodes[parent] else {
        await loadDocument()
        return
      }
      let special = parentNode.childrenIDs.filter { nodes[$0]?.relation != .child }
      for id in parentNode.childrenIDs where nodes[id]?.relation == .child {
        removeDescendants(of: id)
      }
      for child in children { nodes[child.id] = child }
      nodes[parent] = parentNode.replacing(
        childCount: children.count, childrenIDs: children.map(\.id) + special)
    case .attributeModified(let id, let name, let value):
      guard let node = nodes[id] else { return }
      var attributes = node.attributes.filter { $0.name != name }
      attributes.append(ShaarDOMAttribute(name: name, value: value))
      nodes[id] = node.replacing(attributes: attributes)
    case .characterDataModified(let id, let value):
      if let node = nodes[id] { nodes[id] = node.replacing(value: value) }
    case .childCountUpdated(let id, let count):
      if let node = nodes[id] { nodes[id] = node.replacing(childCount: count) }
    }
  }

  private func removeDescendants(of id: Int) {
    guard let node = nodes.removeValue(forKey: id) else { return }
    for child in node.childrenIDs { removeDescendants(of: child) }
  }

  isolated deinit { streamTask?.cancel() }
}
