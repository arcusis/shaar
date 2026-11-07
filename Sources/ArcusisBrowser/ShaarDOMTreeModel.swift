// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

enum ShaarDOMCommand: Equatable {
  case document(depth: Int)
  case children(Int)
  case search(String)
  case searchResults(String, Int)
  case discardSearch(String)
  case describe(Int)
  case describeBackend(Int)
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

/// Where a frontend node sat in the last document. Frontend ids are dropped on
/// navigation; the path and backend id are how a later document finds the same node.
struct ShaarDOMNodeIdentity: Equatable {
  struct Step: Equatable {
    let name: String
    let index: Int
  }

  let backendNodeID: Int?
  let steps: [Step]

  static func capture(_ id: Int, nodes: [Int: ShaarDOMNode], rootID: Int?) -> Self? {
    guard let rootID, let selected = nodes[id] else { return nil }
    var steps: [Step] = []
    var current = id
    while current != rootID {
      guard steps.count < 40, let node = nodes[current],
        let parentID = node.parentID, let parent = nodes[parentID],
        let index = parent.childrenIDs.firstIndex(of: current)
      else { return nil }
      steps.append(Step(name: node.name, index: index))
      current = parentID
    }
    return Self(backendNodeID: selected.backendNodeID, steps: steps.reversed())
  }

  func find(in nodes: [Int: ShaarDOMNode], rootID: Int?) -> Int? {
    if let backendNodeID,
      let sameNode = nodes.values.first(where: { $0.backendNodeID == backendNodeID })
    {
      return sameNode.id
    }
    guard let rootID, nodes[rootID] != nil else { return nil }
    var current = rootID
    for step in steps {
      guard let parent = nodes[current], parent.childrenIDs.indices.contains(step.index) else {
        return nil
      }
      let child = parent.childrenIDs[step.index]
      guard nodes[child]?.name == step.name else { return nil }
      current = child
    }
    return current
  }
}

@MainActor @Observable
final class ShaarDOMTreeModel {
  private(set) var target: SiteControlTarget
  private(set) var available = false
  private(set) var loading = false
  private(set) var nodes: [Int: ShaarDOMNode] = [:]
  private(set) var rootID: Int?
  private(set) var matches: Set<Int> = []
  private(set) var matchOrder: [Int] = []
  private(set) var matchIndex: Int?
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

  var matchCountLabel: String? {
    guard let matchIndex, !matchOrder.isEmpty else { return nil }
    return ShellL10n.format(
      "%d of %d",
      arguments: [.integer(matchIndex + 1), .integer(matchOrder.count)])
  }
  var rows: [ShaarDOMRow] {
    guard let rootID else { return [] }
    var result: [ShaarDOMRow] = []
    func append(_ id: Int, depth: Int) {
      guard depth <= 40, result.count < 20_000, let node = nodes[id] else { return }
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
    ShaarDOMLocator.css(for: id, nodes: nodes)
  }

  func copiedSelector(for id: Int, inspector: InspectorModel) async -> String {
    if let live = await inspector.pathsForDOMNode(id), !live.css.isEmpty {
      return live.css
    }
    await prepareCopyPath(for: id)
    return selector(for: id)
  }

  func xpath(for id: Int) -> String {
    ShaarDOMLocator.xpath(for: id, nodes: nodes)
  }

  /// Loads missing ancestor children so a copy is not taken from a partial document slice.
  func prepareCopyPath(for id: Int) async {
    var ancestors: [Int] = []
    var current: Int? = id
    var depth = 0
    while let value = current, depth < 40 {
      depth += 1
      if let parentID = nodes[value]?.parentID { ancestors.append(parentID) }
      current = nodes[value]?.parentID
    }
    for parent in ancestors.reversed() {
      await loadChildrenIfNeeded(parent)
    }
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
    clearMatches()
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

  /// Asks the inspector session for a fresh document and returns the ids that now
  /// stand where `ids` stood. A reload drops the ids `DOM.resolveNode` still holds.
  func rebindFrontendIDs(_ ids: [Int]) async -> [Int: Int] {
    guard isOpen, available else { return [:] }
    let target = target
    let generation = generation
    let captured = ids.compactMap { id -> (Int, ShaarDOMNodeIdentity)? in
      guard let identity = ShaarDOMNodeIdentity.capture(id, nodes: nodes, rootID: rootID) else {
        return nil
      }
      return (id, identity)
    }
    let previousSelection = selectedID
    await loadDocument()
    guard self.target == target, self.generation == generation,
      failure == nil, rootID != nil
    else { return [:] }
    var mapped: [Int: Int] = [:]
    for (id, identity) in captured {
      if let backend = identity.backendNodeID,
        let bound = await frontendID(forBackend: backend)
      {
        mapped[id] = bound
      } else if let found = identity.find(in: nodes, rootID: rootID) {
        mapped[id] = found
      }
    }
    if let previousSelection {
      if let replacement = mapped[previousSelection] {
        select(replacement)
      } else {
        selectedID = nil
      }
    }
    return mapped
  }

  func loadDocument(depth: Int = 2) async {
    guard available else { return }
    let generation = generation
    let target = target
    loading = true
    defer { if self.generation == generation { loading = false } }
    let bounded = min(max(depth, 1), 12)
    do {
      let reply = try await transport.execute(.document(depth: bounded), for: target)
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
    clearMatches()
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    do {
      let (id, ids) = try await searchResults(for: String(query.prefix(512)))
      searchID = id
      let ordered = uniqueMatchIDs(ids)
      matchOrder = ordered
      matches = Set(ordered)
      if ordered.isEmpty {
        matchIndex = nil
      } else {
        matchIndex = 0
        guard await revealAndSelect(ordered[0]) else {
          clearMatches()
          throw ShaarDOMFailure("DOM search found a match but could not reveal it")
        }
      }
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  private func searchResults(for query: String) async throws -> (String, [Int]) {
    var lastError: Error = ShaarDOMFailure("DOM search could not be completed")
    for attempt in 0..<3 {
      let result = try await execute(.search(query))
      guard let id = result["searchId"] as? String,
        let count = result["resultCount"] as? Int,
        count >= 0, count <= 20_000
      else { throw ShaarDOMFailure("DOM search could not be completed") }
      do {
        let found = try await execute(.searchResults(id, min(count, 500)))
        guard let ids = found["nodeIds"] as? [Int], ids.count <= 500 else {
          throw ShaarDOMFailure("DOM search could not be completed")
        }
        return (id, ids)
      } catch {
        lastError = error
        _ = try? await execute(.discardSearch(id))
        if attempt < 2 { try? await Task.sleep(for: .milliseconds(100)) }
      }
    }
    throw lastError
  }

  func stepSearchMatch(forward: Bool) async {
    let count = matchOrder.count
    guard count > 0, let matchIndex else { return }
    let delta = forward ? 1 : -1
    let next = (matchIndex + delta + count) % count
    if await revealAndSelect(matchOrder[next]) {
      self.matchIndex = next
      failure = nil
    } else {
      failure = ShaarDOMFailure("DOM search found a match but could not reveal it")
        .localizedDescription
    }
  }

  /// A search id can name a node the depth-limited document never loaded. Ask for that node and
  /// attach it under the nearest ancestor already in the tree. If the parent is missing, refresh
  /// progressively deeper bounded slices before reporting that the match could not be revealed.
  private func revealAndSelect(_ id: Int) async -> Bool {
    if nodes[id] == nil {
      await linkUnloadedMatch(id)
    }
    if nodes[id] == nil {
      for depth in [4, 8, 12] {
        await loadDocument(depth: depth)
        if nodes[id] != nil { break }
      }
    }
    guard nodes[id] != nil else { return false }
    select(id)
    return rows.contains { $0.id == id }
  }

  private func linkUnloadedMatch(_ id: Int) async {
    var pending: [[String: Any]] = []
    var cursor: Int? = id
    var steps = 0
    while let nodeID = cursor, nodes[nodeID] == nil, steps < 40 {
      steps += 1
      guard let described = await describedNode(nodeID) else { return }
      pending.append(described)
      cursor = integerValue(described["parentId"])
    }
    guard let anchor = cursor, nodes[anchor] != nil else { return }
    for fields in pending.reversed() {
      guard let parentID = integerValue(fields["parentId"]), nodes[parentID] != nil else {
        return
      }
      guard
        let node = ShaarDOMNode.decode(
          decodedSearchNode(fields), parentID: parentID, relation: .child)
      else { return }
      attach(node, to: parentID)
    }
  }

  private func frontendID(forBackend backend: Int) async -> Int? {
    guard let result = try? await execute(.describeBackend(backend)),
      let node = result["node"] as? [String: Any],
      let id = integerValue(node["nodeId"]), id > 0
    else { return nil }
    return id
  }

  private func describedNode(_ id: Int) async -> [String: Any]? {
    guard let result = try? await execute(.describe(id)),
      let node = result["node"] as? [String: Any],
      integerValue(node["nodeId"]) == id
    else { return nil }
    return node
  }

  private func attach(_ node: ShaarDOMNode, to parentID: Int) {
    guard var parent = nodes[parentID] else { return }
    if !parent.childrenIDs.contains(node.id) {
      var children = parent.childrenIDs
      children.append(node.id)
      parent = parent.replacing(
        childCount: max(parent.childCount, children.count),
        childrenIDs: children)
      nodes[parentID] = parent
    }
    if nodes[node.id] == nil {
      nodes[node.id] = node
    }
  }

  private func decodedSearchNode(_ fields: [String: Any]) -> [String: Any] {
    var payload = fields
    if let nodeID = integerValue(fields["nodeId"]) { payload["nodeId"] = nodeID }
    if let type = integerValue(fields["nodeType"]) { payload["nodeType"] = type }
    if let count = integerValue(fields["childNodeCount"]) { payload["childNodeCount"] = count }
    if payload["nodeValue"] == nil { payload["nodeValue"] = "" }
    if let raw = fields["attributes"] as? [Any] {
      let names = raw.compactMap { $0 as? String }
      if names.count == raw.count { payload["attributes"] = names }
    }
    return payload
  }

  private func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private func styleValue(of node: ShaarDOMNode) -> String {
    node.attributes.first { $0.name.caseInsensitiveCompare("style") == .orderedSame }?.value ?? ""
  }

  private func replaceStyle(_ value: String, on id: Int) {
    guard let node = nodes[id] else { return }
    var attributes = node.attributes.filter {
      $0.name.caseInsensitiveCompare("style") != .orderedSame
    }
    if !value.isEmpty {
      attributes.append(ShaarDOMAttribute(name: "style", value: value))
    }
    nodes[id] = node.replacing(attributes: attributes)
  }

  private func clearMatches() {
    matches = []
    matchOrder = []
    matchIndex = nil
  }

  private func uniqueMatchIDs(_ ids: [Int]) -> [Int] {
    var seen: Set<Int> = []
    var ordered: [Int] = []
    for id in ids where seen.insert(id).inserted {
      ordered.append(id)
    }
    return ordered
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
    guard ShaarDOMDrop.allowed(id: id, parentID: parentID, before: siblingID, nodes: nodes) else {
      return
    }
    await mutate(.move(id, parentID, siblingID))
  }

  func showsHidden(_ node: ShaarDOMNode) -> Bool {
    node.nodeType == 1 && ShaarElementVisibility.isHidden(styleValue(of: node))
  }

  func toggleVisibility() async {
    guard let id = selectedID, let node = nodes[id], node.nodeType == 1 else { return }
    let next = ShaarElementVisibility.toggledStyle(styleValue(of: node))
    do {
      if next.isEmpty {
        _ = try await execute(.removeAttribute(id, "style"))
      } else {
        _ = try await execute(.setAttribute(id, "style", next))
      }
    } catch {
      failure = error.localizedDescription
      return
    }
    replaceStyle(next, on: id)
    failure = nil
    if (try? await execute(.markUndo)) != nil { canUndo = true }
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

  func loadChildrenIfNeeded(_ id: Int) async -> String? {
    guard let node = nodes[id], node.childrenIDs.count < node.childCount else { return nil }
    do { _ = try await execute(.children(id)) } catch {
      return error.localizedDescription
    }
    for _ in 0..<40 {
      let current = nodes[id]
      if (current?.childrenIDs.count ?? 0) >= (current?.childCount ?? 0) { return nil }
      try? await Task.sleep(for: .milliseconds(25))
    }
    let current = nodes[id]
    let have = current?.childrenIDs.count ?? 0
    let need = current?.childCount ?? 0
    return "children stayed \(have) of \(need)"
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
      switch event.mutation {
      case .childrenSet:
        break // Keep the bounded children instead of losing the expanded tree.
      default:
        await loadDocument()
        return
      }
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
      let directChildren = children.filter { $0.parentID == parent }
      let special = parentNode.childrenIDs.filter { nodes[$0]?.relation != .child }
      for id in parentNode.childrenIDs where nodes[id]?.relation == .child {
        removeDescendants(of: id)
      }
      for child in children { nodes[child.id] = child }
      let count = event.truncated
        ? max(parentNode.childCount, directChildren.count) : directChildren.count
      nodes[parent] = parentNode.replacing(
        childCount: count, childrenIDs: directChildren.map(\.id) + special)
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
