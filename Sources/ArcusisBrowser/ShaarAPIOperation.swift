// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarAPIKind: String, Equatable, Sendable {
  case graphql
  case trpc

  var label: String { rawValue }
}

enum ShaarAPICallType: String, Equatable, Sendable {
  case query
  case mutation
  case subscription
  case procedure
  case unknown
}

struct ShaarAPIOperation: Equatable, Sendable {
  var kind: ShaarAPIKind
  var name: String
  var callType: ShaarAPICallType
  var hasErrors: Bool

  var columnText: String {
    if callType == .unknown { return "\(name) · \(kind.label)" }
    return "\(name) · \(callType.rawValue)"
  }

  static func parse(
    method: String, url: String, body: String?, responseBody: String?
  ) -> ShaarAPIOperation? {
    if var operation = graphql(url: url, body: body) {
      if responseHasErrors(.graphql, body: responseBody) { operation.hasErrors = true }
      return operation
    }
    if var operation = trpc(method: method, url: url) {
      if responseHasErrors(.trpc, body: responseBody) { operation.hasErrors = true }
      return operation
    }
    return nil
  }

  static func combine(
    method: String, url: String, payload: String?, responseBody: String?,
    observation: ShaarAPIObservation?
  ) -> ShaarAPIOperation? {
    let fromRow = parse(method: method, url: url, body: payload, responseBody: responseBody)
    let fromObserved = observation.flatMap {
      parse(method: method, url: url, body: $0.postData, responseBody: nil)
    }
    guard var chosen = preferred(method: method, row: fromRow, observed: fromObserved) else {
      return nil
    }
    if responseHasErrors(chosen.kind, body: responseBody) { chosen.hasErrors = true }
    if fromRow?.hasErrors == true { chosen.hasErrors = true }
    if observation?.responseHasErrors == true { chosen.hasErrors = true }
    return chosen
  }

  static func matchKey(method: String, url: String) -> String {
    var components = URLComponents(string: url)
    components?.fragment = nil
    let normalized = components?.string ?? url
    return "\(method.uppercased())\n\(normalized)"
  }

  static func urlMightMatch(_ url: String) -> Bool {
    if url.range(of: "graphql", options: .caseInsensitive) != nil { return true }
    if url.range(of: "/trpc", options: .caseInsensitive) != nil { return true }
    return false
  }
}

struct ShaarAPIObservation: Equatable, Sendable {
  var install: String
  var id: Int
  var method: String
  var url: String
  var postData: String?
  var responseHasErrors: Bool

  static func list(from raw: String) -> [ShaarAPIObservation] {
    guard raw.utf8.count <= 1_048_576,
      let data = raw.data(using: .utf8),
      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    var observations: [ShaarAPIObservation] = []
    for item in items.prefix(100) {
      guard let observation = make(item) else { continue }
      observations.append(observation)
    }
    return observations
  }
}

extension ShaarAPIOperation {
  fileprivate static func preferred(
    method: String, row: ShaarAPIOperation?, observed: ShaarAPIOperation?
  ) -> ShaarAPIOperation? {
    guard let row else { return observed }
    guard let observed else { return row }
    if method.uppercased() == "POST" {
      if usefulName(observed) { return observed }
      if usefulName(row) { return row }
      return observed
    }
    if usefulName(row) { return row }
    if usefulName(observed) { return observed }
    return row
  }

  fileprivate static func usefulName(_ operation: ShaarAPIOperation) -> Bool {
    !operation.name.isEmpty && operation.name != "anonymous"
  }

  fileprivate static func responseHasErrors(_ kind: ShaarAPIKind, body: String?) -> Bool {
    guard let value = jsonValue(body) else { return false }
    switch kind {
    case .graphql: return graphqlErrors(value)
    case .trpc: return trpcErrors(value)
    }
  }

  fileprivate static func graphql(url: String, body: String?) -> ShaarAPIOperation? {
    if let body, let operation = graphqlBody(body, url: url) { return operation }
    return graphqlURL(url)
  }

  fileprivate static func graphqlBody(_ body: String, url: String) -> ShaarAPIOperation? {
    if let value = jsonValue(body) {
      if let object = value as? [String: Any], let named = graphqlFields(object, url: url) {
        return make(.graphql, name: named.name, callType: named.callType)
      }
      if let items = value as? [Any] { return graphqlBatch(items, url: url) }
      return nil
    }
    if let fields = formFields(body), let named = graphqlFields(fields, url: url) {
      return make(.graphql, name: named.name, callType: named.callType)
    }
    guard looksLikeGraphQLDocument(body) else { return nil }
    guard let named = namedOperation(document: body, operationName: nil) else { return nil }
    return make(.graphql, name: named.name, callType: named.callType)
  }

  fileprivate static func graphqlBatch(
    _ items: [Any], url: String
  ) -> ShaarAPIOperation? {
    var parts: [(name: String, callType: ShaarAPICallType)] = []
    for item in items {
      guard let object = item as? [String: Any], let named = graphqlFields(object, url: url) else {
        continue
      }
      parts.append(named)
    }
    guard let first = parts.first else { return nil }
    let name = parts.map(\.name).joined(separator: ", ")
    return make(.graphql, name: name, callType: first.callType)
  }

  fileprivate static func graphqlFields(
    _ object: [String: Any], url: String
  ) -> (name: String, callType: ShaarAPICallType)? {
    let operationName = stringField(object["operationName"])
    let query = stringField(object["query"])
    if let query, !query.isEmpty {
      return namedOperation(document: query, operationName: operationName)
    }
    if hasPersistedQuery(object), let operationName, !operationName.isEmpty {
      return (operationName, .unknown)
    }
    if let operationName, !operationName.isEmpty, urlLooksLikeGraphQL(url) {
      return (operationName, .unknown)
    }
    return nil
  }

  fileprivate static func graphqlURL(_ url: String) -> ShaarAPIOperation? {
    guard let components = URLComponents(string: url) else { return nil }
    let items = components.queryItems ?? []
    let operationName = items.first { $0.name == "operationName" }?.value
    let query = items.first { $0.name == "query" }?.value
    let document = query.flatMap { looksLikeGraphQLDocument($0) ? $0 : nil }
    if document == nil && !urlLooksLikeGraphQL(url) { return nil }
    guard let named = namedOperation(document: document, operationName: operationName) else {
      return nil
    }
    if named.name.isEmpty { return nil }
    if document == nil && operationName?.isEmpty != false { return nil }
    return make(.graphql, name: named.name, callType: named.callType)
  }

  fileprivate static func trpc(method: String, url: String) -> ShaarAPIOperation? {
    guard let components = URLComponents(string: url) else { return nil }
    let parts = components.path.split(separator: "/").map(String.init)
    guard
      let index = parts.lastIndex(where: {
        $0.compare("trpc", options: .caseInsensitive) == .orderedSame
      })
    else { return nil }
    let next = index + 1
    guard next < parts.count else { return nil }
    let names = parts[next].split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter(isProcedureName)
    guard !names.isEmpty else { return nil }
    if !trpcPrefixAllowed(parts, index: index)
      && !trpcExtraSignal(names, items: components.queryItems)
    {
      return nil
    }
    return make(.trpc, name: names.joined(separator: ", "), callType: trpcCallType(method))
  }

  fileprivate static func trpcPrefixAllowed(_ parts: [String], index: Int) -> Bool {
    if index == 0 { return true }
    return parts[index - 1].compare("api", options: .caseInsensitive) == .orderedSame
  }

  fileprivate static func trpcExtraSignal(_ names: [String], items: [URLQueryItem]?) -> Bool {
    if names.contains(where: { $0.contains(".") }) { return true }
    guard let items else { return false }
    return items.contains { $0.name == "batch" || $0.name == "input" }
  }

  fileprivate static func trpcCallType(_ method: String) -> ShaarAPICallType {
    switch method.uppercased() {
    case "GET": .query
    case "POST": .mutation
    default: .procedure
    }
  }

  fileprivate static func namedOperation(
    document: String?, operationName: String?
  ) -> (name: String, callType: ShaarAPICallType)? {
    let scanned = document.map(scanOperations) ?? []
    let explicit = operationName.flatMap { $0.isEmpty ? nil : $0 }
    if scanned.isEmpty {
      if document.map(isShorthandQuery) == true { return (explicit ?? "anonymous", .query) }
      if let explicit { return (explicit, .unknown) }
      return nil
    }
    if let explicit, let match = scanned.first(where: { $0.name == explicit }) {
      return (explicit, match.callType)
    }
    if let explicit { return (explicit, scanned[0].callType) }
    return (scanned[0].name ?? "anonymous", scanned[0].callType)
  }

  fileprivate static func make(
    _ kind: ShaarAPIKind, name: String, callType: ShaarAPICallType
  ) -> ShaarAPIOperation? {
    let bounded = String(name.prefix(400))
    guard !bounded.isEmpty else { return nil }
    return ShaarAPIOperation(kind: kind, name: bounded, callType: callType, hasErrors: false)
  }
}

extension ShaarAPIOperation {
  fileprivate struct ScannedOperation {
    var name: String?
    var callType: ShaarAPICallType
  }

  fileprivate static func scanOperations(_ document: String) -> [ScannedOperation] {
    var found: [ScannedOperation] = []
    var index = document.startIndex
    while index < document.endIndex {
      if document[index] == "#" {
        index = skipLine(document, from: index)
        continue
      }
      if document[index] == "\"" {
        index = skipQuoted(document, from: index)
        continue
      }
      if let keyword = keyword(at: index, in: document) {
        let after = document.index(index, offsetBy: keyword.rawValue.count)
        found.append(ScannedOperation(name: readName(document, from: after), callType: keyword))
        index = after
        continue
      }
      index = document.index(after: index)
    }
    return found
  }

  fileprivate static func keyword(
    at index: String.Index, in document: String
  ) -> ShaarAPICallType? {
    guard isBoundary(document, before: index) else { return nil }
    let words: [ShaarAPICallType] = [.query, .mutation, .subscription]
    for word in words {
      let token = word.rawValue
      guard document[index...].hasPrefix(token) else { continue }
      let after = document.index(index, offsetBy: token.count)
      if after < document.endIndex && isGraphQLNameCharacter(document[after]) { continue }
      return word
    }
    return nil
  }

  fileprivate static func readName(_ document: String, from index: String.Index) -> String? {
    var current = index
    while current < document.endIndex, document[current].isWhitespace {
      current = document.index(after: current)
    }
    guard current < document.endIndex else { return nil }
    let first = document[current]
    guard first == "_" || first.isLetter else { return nil }
    var end = document.index(after: current)
    while end < document.endIndex, isGraphQLNameCharacter(document[end]) {
      end = document.index(after: end)
    }
    let name = String(document[current..<end])
    return name.isEmpty ? nil : name
  }

  fileprivate static func isBoundary(_ document: String, before index: String.Index) -> Bool {
    guard index > document.startIndex else { return true }
    return !isGraphQLNameCharacter(document[document.index(before: index)])
  }

  fileprivate static func isGraphQLNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  fileprivate static func skipLine(_ document: String, from index: String.Index) -> String.Index {
    var current = index
    while current < document.endIndex, document[current] != "\n" {
      current = document.index(after: current)
    }
    guard current < document.endIndex else { return current }
    return document.index(after: current)
  }

  fileprivate static func skipQuoted(_ document: String, from index: String.Index) -> String.Index {
    if document[index...].hasPrefix("\"\"\"") {
      let start = document.index(index, offsetBy: 3)
      guard let range = document[start...].range(of: "\"\"\"") else { return document.endIndex }
      return range.upperBound
    }
    var current = document.index(after: index)
    while current < document.endIndex {
      if document[current] == "\\" {
        let escaped = document.index(after: current)
        current = escaped < document.endIndex ? document.index(after: escaped) : document.endIndex
        continue
      }
      if document[current] == "\"" { return document.index(after: current) }
      current = document.index(after: current)
    }
    return document.endIndex
  }

  fileprivate static func isShorthandQuery(_ document: String) -> Bool {
    document.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
  }

  fileprivate static func looksLikeGraphQLDocument(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") { return true }
    for word in ["query", "mutation", "subscription"] {
      guard trimmed.hasPrefix(word) else { continue }
      let rest = trimmed.dropFirst(word.count)
      if rest.isEmpty { return true }
      let next = rest[rest.startIndex]
      if next.isWhitespace || next == "(" || next == "{" { return true }
    }
    return false
  }

  fileprivate static func urlLooksLikeGraphQL(_ url: String) -> Bool {
    url.range(of: "graphql", options: .caseInsensitive) != nil
  }

  fileprivate static func hasPersistedQuery(_ object: [String: Any]) -> Bool {
    guard let extensions = object["extensions"] as? [String: Any] else { return false }
    return extensions["persistedQuery"] != nil && !(extensions["persistedQuery"] is NSNull)
  }

  fileprivate static func formFields(_ body: String) -> [String: Any]? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("="), !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else {
      return nil
    }
    var fields: [String: Any] = [:]
    for part in trimmed.split(separator: "&") {
      let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pieces.count == 2 else { continue }
      fields[decodeForm(String(pieces[0]))] = decodeForm(String(pieces[1]))
    }
    guard fields["query"] != nil || fields["operationName"] != nil else { return nil }
    return fields
  }

  fileprivate static func decodeForm(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
  }

  fileprivate static func stringField(_ value: Any?) -> String? {
    value as? String
  }

  fileprivate static func isProcedureName(_ name: String) -> Bool {
    guard let first = name.first, first == "_" || first.isLetter else { return false }
    return name.allSatisfy { character in
      character.isLetter || character.isNumber || character == "_" || character == "$"
        || character == "."
    }
  }

  fileprivate static func graphqlErrors(_ value: Any) -> Bool {
    if let items = value as? [Any] { return items.contains { graphqlErrors($0) } }
    guard let object = value as? [String: Any], let errors = object["errors"] as? [Any] else {
      return false
    }
    return !errors.isEmpty
  }

  fileprivate static func trpcErrors(_ value: Any) -> Bool {
    if let items = value as? [Any] { return items.contains { trpcErrors($0) } }
    guard let object = value as? [String: Any] else { return false }
    return object["error"] is [String: Any]
  }

  fileprivate static func jsonValue(_ body: String?) -> Any? {
    guard let body, let data = body.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }
}

extension ShaarAPIObservation {
  fileprivate static func make(_ item: [String: Any]) -> ShaarAPIObservation? {
    guard let install = item["install"] as? String, !install.isEmpty, install.count <= 64,
      let id = jsonInt(item["id"]), id > 0,
      let method = item["method"] as? String, !method.isEmpty,
      let url = item["url"] as? String, !url.isEmpty
    else { return nil }
    let postData = (item["postData"] as? String).map { String($0.prefix(8_000)) }
    return ShaarAPIObservation(
      install: install, id: id, method: method, url: String(url.prefix(2_048)),
      postData: postData, responseHasErrors: jsonBool(item["responseHasErrors"]))
  }

  fileprivate static func jsonInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    return number.intValue
  }

  fileprivate static func jsonBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return number.boolValue
  }
}
