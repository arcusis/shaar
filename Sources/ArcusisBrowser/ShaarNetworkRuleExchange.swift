// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Portable JSON for the saved rules of one site. File paths stay on this Mac.
enum ShaarNetworkRuleExchange {
  static let schemaVersion = 1
  static let maximumBytes = 4_194_304
  static let maximumRules = 100
  static let maximumEnabled = 32

  static func data(from rules: [ShaarNetworkRule]) throws -> Data {
    let rows = try exchangeRows(from: rules)
    let encoded = try JSONEncoder().encode(Document(schemaVersion: schemaVersion, rules: rows))
    guard encoded.count <= maximumBytes else { throw ShaarNetworkRuleError.invalidDocument }
    return encoded
  }

  static func rules(from data: Data) throws -> [ShaarNetworkRule] {
    guard data.count <= maximumBytes else { throw ShaarNetworkRuleError.invalidDocument }
    let document: Document
    do {
      document = try JSONDecoder().decode(Document.self, from: data)
    } catch {
      throw ShaarNetworkRuleError.invalidDocument
    }
    guard document.schemaVersion == schemaVersion, document.rules.count <= maximumRules else {
      throw ShaarNetworkRuleError.invalidDocument
    }
    var rules: [ShaarNetworkRule] = []
    var seen: Set<UUID> = []
    rules.reserveCapacity(document.rules.count)
    for row in document.rules {
      let rule = try rule(from: row)
      guard seen.insert(rule.id).inserted else { throw ShaarNetworkRuleError.invalidDocument }
      rules.append(rule)
    }
    let enabled = rules.filter(\.enabled).count
    guard enabled <= maximumEnabled else { throw ShaarNetworkRuleError.invalidAction }
    return rules
  }

  static func readFile(at url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
      throw ShaarNetworkRuleError.invalidDocument
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumBytes else { throw ShaarNetworkRuleError.invalidDocument }
    return data
  }

  private static func exchangeRows(from rules: [ShaarNetworkRule]) throws -> [Row] {
    guard rules.count <= maximumRules else { throw ShaarNetworkRuleError.invalidAction }
    var rows: [Row] = []
    var seen: Set<UUID> = []
    rows.reserveCapacity(rules.count)
    for rule in rules {
      let row = try row(for: rule)
      guard seen.insert(row.id).inserted else { throw ShaarNetworkRuleError.invalidDocument }
      rows.append(row)
    }
    return rows
  }

  private static func row(for rule: ShaarNetworkRule) throws -> Row {
    let cleaned = rule.normalizedForAction()
    var exported = cleaned
    if cleaned.kind == .mock, let path = cleaned.bodyFilePath, !path.isEmpty {
      let bytes = try cleaned.bodyData()
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw ShaarNetworkRuleError.invalidBody
      }
      exported.bodyText = text
      exported.bodyFilePath = nil
    }
    try exported.validate()
    return Row(
      id: exported.id, enabled: exported.enabled, method: exported.method, url: exported.url,
      kind: token(for: exported.kind), status: exported.status, headers: exported.headers,
      bodyText: exported.bodyText, redirectURL: exported.redirectURL,
      delayMilliseconds: exported.delayMilliseconds)
  }

  private static func rule(from row: Row) throws -> ShaarNetworkRule {
    guard let kind = kind(for: row.kind) else { throw ShaarNetworkRuleError.invalidDocument }
    var rule = ShaarNetworkRule()
    rule.id = row.id
    rule.enabled = row.enabled
    rule.method = row.method
    rule.url = row.url
    rule.kind = kind
    rule.status = row.status
    rule.headers = row.headers
    rule.bodyText = row.bodyText
    rule.redirectURL = row.redirectURL
    rule.delayMilliseconds = row.delayMilliseconds
    let cleaned = rule.normalizedForAction()
    try cleaned.validate()
    return cleaned
  }

  private static func token(for kind: ShaarNetworkRuleKind) -> String {
    switch kind {
    case .mock: "mock"
    case .redirect: "redirect"
    case .delay: "delay"
    case .requestHeaders: "requestHeaders"
    case .responseHeaders: "responseHeaders"
    }
  }

  private static func kind(for token: String) -> ShaarNetworkRuleKind? {
    switch token {
    case "mock": .mock
    case "redirect": .redirect
    case "delay": .delay
    case "requestHeaders": .requestHeaders
    case "responseHeaders": .responseHeaders
    default: nil
    }
  }

  private struct Document: Codable {
    var schemaVersion: Int
    var rules: [Row]
  }

  private struct Row: Codable {
    var id: UUID
    var enabled: Bool
    var method: String
    var url: String
    var kind: String
    var status: Int
    var headers: [ShaarNetworkHeader]
    var bodyText: String
    var redirectURL: String
    var delayMilliseconds: Int
  }
}
