// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation
import Observation

enum ShaarNetworkFilter: String, CaseIterable, Sendable {
  case all = "All"
  case fetch = "Fetch/XHR"
  case script = "JS"
  case style = "CSS"
  case image = "Img"
  case document = "Doc"
  case socket = "WS"
  case errors = "Errors"
}

struct ShaarNetworkRequest: Identifiable, Equatable, Sendable {
  let id: String
  var method: String
  var url: String
  var status: Int?
  var mimeType: String?
  var encodedBytes: Int?
  var startedAt: TimeInterval
  var respondedAt: TimeInterval?
  var completedAt: TimeInterval?
  var failure: String?
  var requestHeaders: [ShaarNetworkHeader]
  var responseHeaders: [ShaarNetworkHeader]
  var payload: String?
  var responseBody: String?
  var responseIsBinary = false
  var previewData: Data?

  var name: String {
    guard let url = URL(string: url) else { return self.url }
    let last = url.lastPathComponent
    return last.isEmpty ? (url.host ?? self.url) : last
  }

  var resource: ShaarNetworkFilter {
    let path = URL(string: url)?.path.lowercased() ?? url.lowercased()
    let mime = mimeType?.lowercased() ?? ""
    if url.hasPrefix("ws:") || url.hasPrefix("wss:") { return .socket }
    if mime.contains("javascript") || path.hasSuffix(".js") || path.hasSuffix(".mjs") {
      return .script
    }
    if mime.contains("css") || path.hasSuffix(".css") { return .style }
    if mime.hasPrefix("image/")
      || [".png", ".jpg", ".jpeg", ".svg", ".webp", ".gif"]
        .contains(where: path.hasSuffix)
    {
      return .image
    }
    if mime.contains("html") || path.hasSuffix(".html") || path == "/" { return .document }
    return .fetch
  }

  var duration: TimeInterval? {
    guard let completedAt else { return nil }
    return max(0, completedAt - startedAt)
  }

  var isError: Bool { failure != nil || (status ?? 0) >= 400 }
  var queryItems: [URLQueryItem] { URLComponents(string: url)?.queryItems ?? [] }
}

struct ShaarNetworkJSONNode: Equatable {
  let name: String
  let value: String?
  let children: [Self]
}

struct ShaarNetworkProjection: Sendable {
  let rows: [ShaarNetworkRequest]
  let totalCount: Int
  let firstTime: TimeInterval
  let lastTime: TimeInterval
}

@MainActor @Observable
final class ShaarNetworkModel {
  var filter = ShaarNetworkFilter.all
  var statusFilter = ShaarNetworkStatusFilter.any
  var search = ""
  var selectedID: String?
  var detailTab = DetailTab.headers
  let conditions = ShaarNetworkConditionsModel()
  let projection = ShaarDevToolsListProjection<ShaarNetworkProjection>()
  private(set) var responseBodies: [String: ShaarStoredResponseBody] = [:]
  @ObservationIgnored var loadBody: (@MainActor (String) async throws -> ShaarStoredResponseBody)?
  @ObservationIgnored private var lastEvents: [ShaarDevToolsEvent] = []
  @ObservationIgnored private var loadingBodyIDs: Set<String> = []

  enum DetailTab: String, CaseIterable {
    case headers = "Headers"
    case payload = "Payload"
    case response = "Response"
    case preview = "Preview"
    case timing = "Timing"
  }

  func clearSelection() {
    projection.clear()
    selectedID = nil
    detailTab = .headers
  }

  func resetLog() {
    responseBodies.removeAll()
    loadingBodyIDs.removeAll()
    clearSelection()
  }

  func selectAdjacent(in rows: [ShaarNetworkRequest], forward: Bool, from focusedID: String? = nil)
  {
    guard !rows.isEmpty else {
      selectedID = nil
      return
    }
    let currentID = focusedID ?? selectedID
    let index = rows.firstIndex { $0.id == currentID }
    let next =
      index.flatMap {
        ShaarDevToolsNavigation.adjacentIndex($0, count: rows.count, forward: forward)
      } ?? 0
    selectedID = rows[next].id
  }

  func requests(from events: [ShaarDevToolsEvent]) -> [ShaarNetworkRequest] {
    Self.buildRequests(events, failureLabel: ShellL10n.string("Request failed"))
  }

  func scheduleRows(from events: [ShaarDevToolsEvent]) {
    lastEvents = events
    let filter = filter
    let statusFilter = statusFilter
    let search = search
    let bodies = responseBodies
    let failureLabel = ShellL10n.string("Request failed")
    projection.schedule {
      let requests = Self.applyBodies(
        Self.buildRequests(events, failureLabel: failureLabel), bodies: bodies)
      let visible = Self.filterRequests(
        requests, filter: filter, status: statusFilter, search: search)
      return ShaarNetworkProjection(
        rows: visible, totalCount: requests.count,
        firstTime: visible.map(\.startedAt).min() ?? 0,
        lastTime: visible.map { $0.completedAt ?? $0.startedAt }.max() ?? 0)
    }
  }

  func exportRequests(from events: [ShaarDevToolsEvent]) -> [ShaarNetworkRequest] {
    Self.applyBodies(requests(from: events), bodies: responseBodies)
  }

  func loadResponseBody(id: String) async {
    guard responseBodies[id] == nil, !loadingBodyIDs.contains(id), let loadBody else { return }
    if requests(from: lastEvents).first(where: { $0.id == id })?.responseBody != nil { return }
    loadingBodyIDs.insert(id)
    defer { loadingBodyIDs.remove(id) }
    do {
      responseBodies[id] = try await loadBody(id)
      scheduleRows(from: lastEvents)
    } catch {
      return
    }
  }

  nonisolated private static func buildRequests(
    _ events: [ShaarDevToolsEvent], failureLabel: String
  ) -> [ShaarNetworkRequest] {
    var rows: [ShaarNetworkRequest] = []
    var indexes: [String: Int] = [:]
    for case .network(let event) in events {
      if let index = indexes[event.requestID] {
        merge(event, into: &rows[index], failureLabel: failureLabel)
      } else {
        indexes[event.requestID] = rows.count
        var row = ShaarNetworkRequest(
          id: event.requestID, method: event.method, url: event.url, status: nil,
          mimeType: nil, encodedBytes: nil, startedAt: event.time,
          respondedAt: nil, completedAt: nil, failure: nil,
          requestHeaders: [], responseHeaders: [],
          payload: nil, responseBody: nil)
        merge(event, into: &row, failureLabel: failureLabel)
        rows.append(row)
      }
    }
    reconcileDocumentMethods(in: &rows)
    return rows.filter { !$0.url.isEmpty }
  }

  nonisolated private static func reconcileDocumentMethods(in rows: inout [ShaarNetworkRequest]) {
    var methodsByURL: [String: Set<String>] = [:]
    for row in rows where !row.method.isEmpty && row.resource == .document {
      methodsByURL[row.url, default: []].insert(row.method)
    }
    for index in rows.indices where rows[index].method.isEmpty && rows[index].resource == .document {
      guard let methods = methodsByURL[rows[index].url], methods.count == 1,
        let method = methods.first
      else { continue }
      rows[index].method = method
    }
  }

  func visibleRequests(from events: [ShaarDevToolsEvent]) -> [ShaarNetworkRequest] {
    Self.filterRequests(
      Self.applyBodies(requests(from: events), bodies: responseBodies),
      filter: filter, status: statusFilter, search: search)
  }

  nonisolated private static func filterRequests(
    _ requests: [ShaarNetworkRequest], filter: ShaarNetworkFilter,
    status: ShaarNetworkStatusFilter, search: String
  ) -> [ShaarNetworkRequest] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return requests.filter { row in
      if filter == .errors && !row.isError { return false }
      if filter != .all && filter != .errors && filter != row.resource { return false }
      guard status.matches(row) else { return false }
      return needle.isEmpty || row.url.localizedStandardContains(needle)
        || row.method.localizedStandardContains(needle)
        || row.status.map(String.init)?.contains(needle) == true
    }
  }

  nonisolated private static func applyBodies(
    _ rows: [ShaarNetworkRequest], bodies: [String: ShaarStoredResponseBody]
  ) -> [ShaarNetworkRequest] {
    guard !bodies.isEmpty else { return rows }
    return rows.map { row in
      guard let stored = bodies[row.id] else { return row }
      var copy = row
      let presented = ShaarNetworkBodyPresentation.apply(stored, mime: row.mimeType)
      copy.responseBody = presented.text
      copy.previewData = presented.image
      copy.responseIsBinary = presented.binary
      return copy
    }
  }

  func jsonTree(for body: String) -> [ShaarNetworkJSONNode]? {
    guard body.utf8.count <= 1_048_576,
      let data = body.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    var remaining = 256
    return [Self.node("Response", value: value, depth: 0, remaining: &remaining)]
  }

  func curlCommand(for row: ShaarNetworkRequest) -> String {
    var parts = ["curl", "-X", Self.shellQuote(row.method), Self.shellQuote(row.url)]
    for header in row.requestHeaders.prefix(32) {
      parts.append("-H")
      parts.append(Self.shellQuote("\(header.name): \(ShaarNetworkHeaderRedaction.value(header))"))
    }
    if let payload = row.payload { parts += ["--data-raw", Self.shellQuote(payload)] }
    return parts.joined(separator: " ")
  }

  func fetchCommand(for row: ShaarNetworkRequest) -> String {
    var fields = ["method: \(Self.jsonQuote(row.method))"]
    if !row.requestHeaders.isEmpty {
      let headers = row.requestHeaders.prefix(32).map {
        "\(Self.jsonQuote($0.name)): \(Self.jsonQuote(ShaarNetworkHeaderRedaction.value($0)))"
      }.joined(separator: ", ")
      fields.append("headers: { \(headers) }")
    }
    if let payload = row.payload { fields.append("body: \(Self.jsonQuote(payload))") }
    return "fetch(\(Self.jsonQuote(row.url)), { \(fields.joined(separator: ", ")) });"
  }

  func agentCopyText(for row: ShaarNetworkRequest) -> String {
    var lines = ["\(row.method) \(row.url)"]
    if let status = row.status { lines.append("Status: \(status)") }
    if let mimeType = row.mimeType { lines.append("Type: \(mimeType)") }
    if let encodedBytes = row.encodedBytes { lines.append("Size: \(encodedBytes) bytes") }
    if let duration = row.duration {
      lines.append("Time: \(Int((duration * 1_000).rounded())) ms")
    }
    if let failure = row.failure { lines.append("Failure: \(failure)") }
    for header in row.responseHeaders.prefix(20) {
      lines.append("\(header.name): \(ShaarNetworkHeaderRedaction.value(header))")
    }
    return String(lines.joined(separator: "\n").prefix(16_384))
  }

  nonisolated private static func merge(
    _ event: ShaarNetworkEvent, into row: inout ShaarNetworkRequest, failureLabel: String
  ) {
    if !event.method.isEmpty { row.method = event.method }
    if !event.url.isEmpty { row.url = event.url }
    if let status = event.status { row.status = status }
    if let mimeType = event.mimeType { row.mimeType = mimeType }
    if !event.requestHeaders.isEmpty { row.requestHeaders = event.requestHeaders }
    if !event.responseHeaders.isEmpty { row.responseHeaders = event.responseHeaders }
    if let payload = event.payload { row.payload = payload }
    if let responseBody = event.responseBody { row.responseBody = responseBody }
    switch event.phase {
    case .request: row.startedAt = event.time
    case .response: row.respondedAt = event.time
    case .data: row.encodedBytes = (row.encodedBytes ?? 0) + (event.encodedBytes ?? 0)
    case .finished:
      row.completedAt = event.time
      if let encodedBytes = event.encodedBytes { row.encodedBytes = encodedBytes }
    case .failed:
      row.completedAt = event.time
      row.failure = event.failure ?? failureLabel
    }
  }

  private static func shellQuote(_ text: String) -> String {
    "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func jsonQuote(_ text: String) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
      let result = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return result
  }

  private static func node(
    _ name: String, value: Any, depth: Int, remaining: inout Int
  ) -> ShaarNetworkJSONNode {
    remaining -= 1
    guard depth < 6 else { return .init(name: name, value: "…", children: []) }
    if let object = value as? [String: Any] {
      var children: [ShaarNetworkJSONNode] = []
      for key in object.keys.sorted().prefix(100) where remaining > 0 {
        if let child = object[key] {
          children.append(node(key, value: child, depth: depth + 1, remaining: &remaining))
        }
      }
      if children.count < object.count {
        children.append(.init(name: "…", value: nil, children: []))
      }
      return .init(name: name, value: nil, children: children)
    }
    if let array = value as? [Any] {
      var children: [ShaarNetworkJSONNode] = []
      for (index, child) in array.prefix(100).enumerated() where remaining > 0 {
        children.append(
          node(
            "[\(index)]", value: child, depth: depth + 1,
            remaining: &remaining))
      }
      if children.count < array.count {
        children.append(.init(name: "…", value: nil, children: []))
      }
      return .init(name: name, value: nil, children: children)
    }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .init(name: name, value: number.boolValue ? "true" : "false", children: [])
    }
    return .init(name: name, value: String(String(describing: value).prefix(4_096)), children: [])
  }
}
