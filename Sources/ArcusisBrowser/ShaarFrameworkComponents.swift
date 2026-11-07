// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarFrameworkAccess {
  static func allows(url: URL, enabledHost: String?) -> Bool {
    guard let host = host(url) else { return false }
    if isLoopback(host) { return true }
    guard let enabledHost else { return false }
    return host == enabledHost
  }

  static func host(_ url: URL) -> String? {
    guard isWeb(url), let value = url.host(percentEncoded: false)?.lowercased() else { return nil }
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
    return trimmed
  }

  static func isLoopback(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    return host == "127.0.0.1" || host == "::1"
  }

  static func isWeb(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }
}

enum ShaarFrameworkKind: String, Equatable, Sendable {
  case react
  case vue
  case angular

  var title: String {
    switch self {
    case .react: "React"
    case .vue: "Vue"
    case .angular: "Angular"
    }
  }
}

struct ShaarFrameworkField: Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var value: String
}

struct ShaarFrameworkNode: Equatable, Identifiable, Sendable {
  var id: String
  var parentID: String?
  var name: String
  var key: String?
  var props: [ShaarFrameworkField]
  var state: [ShaarFrameworkField]
}

struct ShaarFrameworkRow: Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var depth: Int
  var key: String?
}

struct ShaarFrameworkSnapshot: Equatable, Sendable {
  var framework: ShaarFrameworkKind?
  var nodes: [ShaarFrameworkNode]
  var rows: [ShaarFrameworkRow]
}

struct ShaarFrameworkFailure: Error, Equatable {
  var reason: String
}

enum ShaarFrameworkLimits {
  static let nodes = 80
  static let depth = 12
  static let fields = 12
  static let name = 80
  static let value = 120
  static let key = 40
}

enum ShaarFrameworkSnapshotParser {
  static func parse(_ value: Any?) throws -> ShaarFrameworkSnapshot {
    guard let root = value as? [String: Any], integer(root["schema"]) == 1 else {
      throw ShaarFrameworkFailure(reason: "schema")
    }
    let framework = try kind(root["framework"])
    let nodes = try nodes(root["nodes"])
    if nodes.isEmpty {
      guard framework == nil else { throw ShaarFrameworkFailure(reason: "empty framework") }
    } else if framework == nil {
      throw ShaarFrameworkFailure(reason: "missing framework")
    }
    let rows = try rows(for: nodes)
    return ShaarFrameworkSnapshot(framework: framework, nodes: nodes, rows: rows)
  }

  private static func kind(_ value: Any?) throws -> ShaarFrameworkKind? {
    if value == nil || value is NSNull { return nil }
    guard let raw = value as? String else { throw ShaarFrameworkFailure(reason: "framework") }
    guard let kind = ShaarFrameworkKind(rawValue: raw) else {
      throw ShaarFrameworkFailure(reason: "framework")
    }
    return kind
  }

  private static func nodes(_ value: Any?) throws -> [ShaarFrameworkNode] {
    guard let value else { return [] }
    guard let items = value as? [Any], items.count <= ShaarFrameworkLimits.nodes else {
      throw ShaarFrameworkFailure(reason: "nodes")
    }
    var nodes: [ShaarFrameworkNode] = []
    var seen: Set<String> = []
    for item in items {
      let node = try node(item)
      guard seen.insert(node.id).inserted else { throw ShaarFrameworkFailure(reason: "duplicate") }
      nodes.append(node)
    }
    for node in nodes {
      guard let parentID = node.parentID else { continue }
      guard parentID != node.id, seen.contains(parentID) else {
        throw ShaarFrameworkFailure(reason: "parent")
      }
    }
    return nodes
  }

  private static func node(_ value: Any) throws -> ShaarFrameworkNode {
    guard let fields = value as? [String: Any],
      let id = fields["id"] as? String, ShaarFrameworkPageScript.isComponentID(id),
      let name = line(fields["name"], limit: ShaarFrameworkLimits.name)
    else { throw ShaarFrameworkFailure(reason: "node") }
    return ShaarFrameworkNode(
      id: id, parentID: try parent(fields["parentID"]), name: name, key: try key(fields["key"]),
      props: try properties(fields["props"]), state: try properties(fields["state"]))
  }

  private static func parent(_ value: Any?) throws -> String? {
    if value == nil || value is NSNull { return nil }
    guard let id = value as? String, ShaarFrameworkPageScript.isComponentID(id) else {
      throw ShaarFrameworkFailure(reason: "parent")
    }
    return id
  }

  private static func key(_ value: Any?) throws -> String? {
    if value == nil || value is NSNull { return nil }
    guard let text = line(value, limit: ShaarFrameworkLimits.key) else {
      throw ShaarFrameworkFailure(reason: "key")
    }
    return text
  }

  private static func properties(_ value: Any?) throws -> [ShaarFrameworkField] {
    guard let value else { return [] }
    guard let items = value as? [Any], items.count <= ShaarFrameworkLimits.fields else {
      throw ShaarFrameworkFailure(reason: "fields")
    }
    var fields: [ShaarFrameworkField] = []
    for (index, item) in items.enumerated() {
      guard let record = item as? [String: Any],
        let name = line(record["name"], limit: ShaarFrameworkLimits.key),
        let raw = record["value"] as? String, raw.utf16.count <= ShaarFrameworkLimits.value,
        !raw.unicodeScalars.contains(where: { $0.value < 32 })
      else { throw ShaarFrameworkFailure(reason: "field") }
      fields.append(ShaarFrameworkField(id: "\(index)", name: name, value: raw))
    }
    return fields
  }

  static func rows(for nodes: [ShaarFrameworkNode]) throws -> [ShaarFrameworkRow] {
    var children: [String: [ShaarFrameworkNode]] = [:]
    for node in nodes {
      children[node.parentID ?? "", default: []].append(node)
    }
    var rows: [ShaarFrameworkRow] = []
    var emitted: Set<String> = []
    func visit(parent: String, depth: Int) throws {
      if depth > ShaarFrameworkLimits.depth { throw ShaarFrameworkFailure(reason: "depth") }
      for node in children[parent] ?? [] {
        guard emitted.insert(node.id).inserted else {
          throw ShaarFrameworkFailure(reason: "cycle")
        }
        rows.append(ShaarFrameworkRow(id: node.id, name: node.name, depth: depth, key: node.key))
        try visit(parent: node.id, depth: depth + 1)
      }
    }
    try visit(parent: "", depth: 0)
    guard emitted.count == nodes.count else { throw ShaarFrameworkFailure(reason: "orphan") }
    return rows
  }

  private static func line(_ value: Any?, limit: Int) -> String? {
    guard let text = value as? String, (1...limit).contains(text.utf16.count) else { return nil }
    guard !text.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
    return text
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    return number.intValue
  }
}

@MainActor
protocol ShaarFrameworkPageEvaluating: AnyObject {
  func evaluateFramework(_ expression: String) async throws -> Any?
}

extension InspectorModel: ShaarFrameworkPageEvaluating {
  func evaluateFramework(_ expression: String) async throws -> Any? {
    try await evaluate(expression)
  }
}

@MainActor @Observable
final class ShaarFrameworkComponentsModel {
  private(set) var framework: ShaarFrameworkKind?
  private(set) var nodes: [ShaarFrameworkNode] = []
  private(set) var rows: [ShaarFrameworkRow] = []
  private(set) var allowed = false
  private(set) var inspected = false
  private(set) var loading = false
  private(set) var failure: String?
  var selectedID: String?
  private var pageURL: URL?
  private var enabledHost: String?
  private var generation = 0
  private var highlightEpoch = 0
  private var attachment = 0
  @ObservationIgnored private weak var page: (any ShaarFrameworkPageEvaluating)?

  var selected: ShaarFrameworkNode? {
    nodes.first { $0.id == selectedID }
  }

  var canEnableSite: Bool {
    guard let pageURL, let host = ShaarFrameworkAccess.host(pageURL) else { return false }
    return !allowed && !ShaarFrameworkAccess.isLoopback(host)
  }

  func attach(_ page: any ShaarFrameworkPageEvaluating) {
    attachment += 1
    self.page = page
  }

  func updateAccess(url: URL) {
    pageURL = url
    allowed = ShaarFrameworkAccess.allows(url: url, enabledHost: enabledHost)
    if !allowed {
      clearTree()
      inspected = false
      failure = nil
    }
  }

  func enableCurrentSite() {
    guard let pageURL, let host = ShaarFrameworkAccess.host(pageURL),
      !ShaarFrameworkAccess.isLoopback(host)
    else { return }
    enabledHost = host
    allowed = ShaarFrameworkAccess.allows(url: pageURL, enabledHost: enabledHost)
  }

  func activate() {
    Task { await refresh() }
  }

  func suspend() {
    generation += 1
    Task { await highlight(nil) }
  }

  func beginHide() -> (epoch: Int, attachment: Int) {
    generation += 1
    highlightEpoch += 1
    clearTree()
    inspected = false
    failure = nil
    loading = false
    return (highlightEpoch, attachment)
  }

  func finishHide(epoch: Int, attachment: Int) async {
    let current = page
    await Self.clearHighlight(current, epoch: epoch)
    if self.attachment == attachment { page = nil }
  }

  func refresh() async {
    generation += 1
    let token = generation
    loading = true
    guard allowed else {
      clearTree()
      inspected = true
      failure = nil
      finishLoading(token)
      return
    }
    guard let page else {
      clearTree()
      inspected = true
      failure = ShellL10n.string("Live component tree is unavailable for this tab")
      finishLoading(token)
      return
    }
    do {
      let value = try await page.evaluateFramework(ShaarFrameworkPageScript.inspect)
      guard token == generation else { return }
      let snapshot = try ShaarFrameworkSnapshotParser.parse(value)
      guard token == generation else { return }
      apply(snapshot)
      failure = nil
      inspected = true
    } catch {
      guard token == generation else { return }
      clearTree()
      inspected = true
      failure = ShellL10n.string("The component tree could not be read.")
    }
    finishLoading(token)
  }

  func select(_ id: String) {
    guard nodes.contains(where: { $0.id == id }) else { return }
    selectedID = id
    Task { await highlight(id) }
  }

  func selectAdjacent(forward: Bool) {
    guard !rows.isEmpty else { return }
    let delta = forward ? 1 : -1
    let next: Int
    if let index = rows.firstIndex(where: { $0.id == selectedID }) {
      next = min(rows.count - 1, max(0, index + delta))
    } else if forward {
      next = 0
    } else {
      next = rows.count - 1
    }
    select(rows[next].id)
  }

  func highlight(_ id: String?) async {
    highlightEpoch += 1
    let epoch = highlightEpoch
    guard let page, let expression = ShaarFrameworkPageScript.highlightExpression(id: id, epoch: epoch)
    else { return }
    _ = try? await page.evaluateFramework(expression)
  }

  private func apply(_ snapshot: ShaarFrameworkSnapshot) {
    framework = snapshot.framework
    nodes = snapshot.nodes
    rows = snapshot.rows
    if let selectedID, nodes.contains(where: { $0.id == selectedID }) { return }
    selectedID = rows.first?.id
  }

  private func clearTree() {
    framework = nil
    nodes = []
    rows = []
    selectedID = nil
  }

  private func finishLoading(_ token: Int) {
    if token == generation { loading = false }
  }

  private static func clearHighlight(
    _ page: (any ShaarFrameworkPageEvaluating)?, epoch: Int
  ) async {
    guard let page,
      let expression = ShaarFrameworkPageScript.highlightExpression(id: nil, epoch: epoch)
    else { return }
    _ = try? await page.evaluateFramework(expression)
  }
}
