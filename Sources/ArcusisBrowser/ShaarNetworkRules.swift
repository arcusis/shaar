// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import Observation

enum ShaarNetworkRuleKind: String, CaseIterable, Codable, Sendable {
  case mock = "Mock response"
  case redirect = "Redirect"
  case delay = "Delay"
  case requestHeaders = "Request headers"
  case responseHeaders = "Response headers"
}

enum ShaarNetworkRuleError: LocalizedError {
  case invalidMatch
  case invalidAction
  case invalidHeaders
  case invalidBody
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidMatch: "Use an exact HTTP or HTTPS request URL and method."
    case .invalidAction: "Check the rule action and its values."
    case .invalidHeaders: "Header names and values must be valid and bounded."
    case .invalidBody: "The response body must be a regular file or text up to 1 MB."
    case .unavailable: "Network rules need engine support."
    }
  }
}

struct ShaarNetworkRule: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var enabled = false
  var method = "GET"
  var url = ""
  var kind = ShaarNetworkRuleKind.mock
  var status = 200
  var headers: [ShaarNetworkHeader] = []
  var bodyText = ""
  var bodyFilePath: String?
  var redirectURL = ""
  var delayMilliseconds = 0

  static func fromRequest(_ request: ShaarNetworkRequest) -> Self {
    var rule = Self()
    rule.method = request.method
    rule.url = request.url
    rule.status = request.status ?? 200
    rule.bodyText = request.responseBody ?? ""
    return rule
  }

  func validate() throws {
    let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    guard methods.contains(method), Self.webURL(url) else {
      throw ShaarNetworkRuleError.invalidMatch
    }
    guard headers.count <= 32, headers.allSatisfy(Self.validHeader) else {
      throw ShaarNetworkRuleError.invalidHeaders
    }
    switch kind {
    case .mock:
      guard (100...599).contains(status), bodyText.utf8.count <= 1_048_576 else {
        throw ShaarNetworkRuleError.invalidAction
      }
      if let bodyFilePath, bodyFilePath.isEmpty || !bodyFilePath.hasPrefix("/") {
        throw ShaarNetworkRuleError.invalidBody
      }
    case .redirect:
      guard Self.webURL(redirectURL) else { throw ShaarNetworkRuleError.invalidAction }
    case .delay:
      guard (0...30_000).contains(delayMilliseconds) else {
        throw ShaarNetworkRuleError.invalidAction
      }
    case .requestHeaders, .responseHeaders:
      guard !headers.isEmpty else { throw ShaarNetworkRuleError.invalidHeaders }
    }
  }

  func bodyData() throws -> Data {
    guard let bodyFilePath, !bodyFilePath.isEmpty else { return Data(bodyText.utf8) }
    let file = URL(fileURLWithPath: bodyFilePath)
    guard file.path == bodyFilePath,
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
      let handle = try? FileHandle(forReadingFrom: file)
    else { throw ShaarNetworkRuleError.invalidBody }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 1_048_577),
      data.count <= 1_048_576
    else { throw ShaarNetworkRuleError.invalidBody }
    return data
  }

  private static func webURL(_ value: String) -> Bool {
    guard value.utf8.count <= 4_096,
      let parts = URLComponents(string: value),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.fragment == nil
    else { return false }
    guard let port = parts.port else { return true }
    return (1...65_535).contains(port)
  }

  private static func validHeader(_ header: ShaarNetworkHeader) -> Bool {
    let token = "!#$%&'*+-.^_`|~"
    let name = header.name.utf8
    guard !name.isEmpty, name.count <= 128, header.value.utf8.count <= 4_096,
      !header.value.utf8.contains(0),
      !header.value.utf8.contains(10), !header.value.utf8.contains(13)
    else { return false }
    return name.allSatisfy { byte in
      (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122) || token.utf8.contains(byte)
    }
  }
}

/// File bodies are read in the app; the engine contract receives only bounded bytes.
struct ShaarResolvedNetworkRule: Equatable, Sendable {
  let id: UUID
  let method: String
  let url: String
  let kind: ShaarNetworkRuleKind
  let status: Int
  let headers: [ShaarNetworkHeader]
  let bodyBase64: String?
  let redirectURL: String
  let delayMilliseconds: Int

  init(_ rule: ShaarNetworkRule) throws {
    try rule.validate()
    id = rule.id
    method = rule.method
    url = rule.url
    kind = rule.kind
    status = rule.status
    headers = rule.headers
    bodyBase64 = rule.kind == .mock ? try rule.bodyData().base64EncodedString() : nil
    redirectURL = rule.redirectURL
    delayMilliseconds = rule.delayMilliseconds
  }
}

struct ShaarNetworkRuleStore {
  private struct Envelope: Codable {
    let schemaVersion: Int
    let rules: [ShaarNetworkRule]
  }

  let root: URL

  init(root: URL? = nil) {
    self.root =
      root
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Shaar/NetworkRules")
  }

  func fileURL(for project: String) -> URL {
    let digest = SHA256.hash(data: Data(project.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return root.appending(path: "\(name).json")
  }

  func load(for project: String) throws -> [ShaarNetworkRule] {
    let file = fileURL(for: project)
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize,
      size <= 4_194_304
    else { throw ShaarNetworkRuleError.invalidBody }
    let data = try Data(contentsOf: file)
    guard data.count <= 4_194_304 else { throw ShaarNetworkRuleError.invalidBody }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.schemaVersion == 1, envelope.rules.count <= 100 else {
      throw ShaarNetworkRuleError.invalidAction
    }
    for rule in envelope.rules { try rule.validate() }
    return envelope.rules
  }

  func save(_ rules: [ShaarNetworkRule], for project: String) throws {
    guard rules.count <= 100 else { throw ShaarNetworkRuleError.invalidAction }
    for rule in rules { try rule.validate() }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, rules: rules))
    guard data.count <= 4_194_304 else { throw ShaarNetworkRuleError.invalidBody }
    let file = fileURL(for: project)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

@MainActor protocol ShaarNetworkRulesTransport {
  var available: Bool { get }
  func apply(_ rules: [ShaarResolvedNetworkRule], to target: SiteControlTarget) async throws
}

struct ShaarNetworkRulesPendingTransport: ShaarNetworkRulesTransport {
  let available = false

  func apply(_ rules: [ShaarResolvedNetworkRule], to target: SiteControlTarget) async throws {
    throw ShaarNetworkRuleError.unavailable
  }
}

@MainActor @Observable
final class ShaarNetworkRulesModel {
  private(set) var target: SiteControlTarget
  private(set) var rules: [ShaarNetworkRule] = []
  private(set) var activeCount = 0
  var draft: ShaarNetworkRule?
  var showingRules = false
  var failure: String?
  @ObservationIgnored private let store: ShaarNetworkRuleStore
  @ObservationIgnored private let transport: any ShaarNetworkRulesTransport
  @ObservationIgnored private var generation = 0

  var available: Bool { transport.available }
  var project: String? {
    target.origin.map { "\(target.profileID.uuidString)|\($0)" }
  }

  init(
    target: SiteControlTarget, store: ShaarNetworkRuleStore = ShaarNetworkRuleStore(),
    transport: any ShaarNetworkRulesTransport = ShaarNetworkRulesPendingTransport()
  ) {
    self.target = target
    self.store = store
    self.transport = transport
    load()
  }

  func create(from request: ShaarNetworkRequest) {
    draft = .fromRequest(request)
    showingRules = true
    failure = nil
  }

  func createNew() {
    draft = ShaarNetworkRule()
    showingRules = true
    failure = nil
  }

  func edit(_ rule: ShaarNetworkRule) {
    draft = rule
    showingRules = true
    failure = nil
  }

  func saveDraft() async throws {
    guard let project, let draft else { throw ShaarNetworkRuleError.invalidMatch }
    try draft.validate()
    var updated = rules
    if let index = updated.firstIndex(where: { $0.id == draft.id }) {
      updated[index] = draft
    } else {
      updated.append(draft)
    }
    try store.save(updated, for: project)
    rules = updated
    self.draft = nil
    try await activate()
  }

  func remove(_ rule: ShaarNetworkRule) async throws {
    guard let project else { throw ShaarNetworkRuleError.invalidMatch }
    let updated = rules.filter { $0.id != rule.id }
    try store.save(updated, for: project)
    rules = updated
    if draft?.id == rule.id { draft = nil }
    try await activate()
  }

  func activate() async throws {
    generation += 1
    let generation = generation
    let target = target
    activeCount = 0
    guard available else { return }
    let enabled = rules.filter(\.enabled)
    guard enabled.count <= 32 else { throw ShaarNetworkRuleError.invalidAction }
    let resolved = try enabled.map(ShaarResolvedNetworkRule.init)
    try await transport.apply(resolved, to: target)
    guard self.generation == generation, self.target == target else { return }
    activeCount = enabled.count
    failure = nil
  }

  func resume() {
    guard available else { return }
    let generation = generation
    Task { [weak self] in
      guard let self, self.generation == generation else { return }
      try? await self.activate()
    }
  }

  func updateTarget(_ target: SiteControlTarget) {
    guard self.target != target else { return }
    self.target = target
    generation += 1
    activeCount = 0
    draft = nil
    showingRules = false
    load()
  }

  func close() {
    generation += 1
    activeCount = 0
    draft = nil
    showingRules = false
  }

  private func load() {
    guard let project else {
      rules = []
      failure = nil
      return
    }
    do {
      rules = try store.load(for: project)
      failure = nil
    } catch {
      rules = []
      failure = error.localizedDescription
    }
  }
}
