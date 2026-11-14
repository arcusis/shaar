// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Observation

enum AgentBridgeFailure: LocalizedError {
  case invalidReply
  var errorDescription: String? { ShellL10n.string("The agent bridge returned an invalid reply.") }
}

enum AgentBridgeOperation: Int {
  case enable = 1005
  case disable = 1006
  case status = 1007
}

struct AgentBridgeConnection: Equatable, Identifiable {
  let index: Int
  var id: Int { index }
  var title: String {
    ShellL10n.format("Local agent %d", arguments: [.integer(index)])
  }
}

enum AgentBridgeSetup {
  static func invocation(endpoint: String) -> String {
    let header = "'{\"Authorization\":\"Bearer <token>\"}'"
    return "npx -y chrome-devtools-mcp@latest --wsEndpoint=\(endpoint) --wsHeaders=\(header)"
  }

  static func command(
    for client: AgentBridgeModel.Client, endpoint: String, token: String
  ) -> String {
    let header = bearerHeader(token)
    let flags = "--wsEndpoint=\(endpoint) --wsHeaders='\(header)'"
    switch client {
    case .claude:
      return "claude mcp add shaar-agent -- npx -y chrome-devtools-mcp@latest \(flags)"
    case .codex:
      return "codex mcp add shaar-agent -- npx -y chrome-devtools-mcp@latest \(flags)"
    case .cursor:
      return cursorConfiguration(endpoint: endpoint, header: header)
    }
  }

  private static func bearerHeader(_ token: String) -> String {
    #"{"Authorization":"Bearer "# + token + #""}"#
  }

  private static func cursorConfiguration(endpoint: String, header: String) -> String {
    let value: [String: Any] = [
      "mcpServers": [
        "shaar-agent": [
          "command": "npx",
          "args": [
            "-y", "chrome-devtools-mcp@latest",
            "--wsEndpoint=\(endpoint)", "--wsHeaders=\(header)",
          ],
        ]
      ]
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }
}

struct AgentBridgeStatus: Equatable {
  let enabled: Bool
  let port: Int?
  let wsEndpoint: String?
  let connectionCount: Int

  static let disabled = AgentBridgeStatus(
    enabled: false, port: nil, wsEndpoint: nil, connectionCount: 0)

  static func decode(_ value: [String: Any]) throws -> Self {
    let allowed: Set<String> = [
      "schemaVersion", "enabled", "port", "wsEndpoint", "connectionCount", "expiresAt",
    ]
    guard Set(value.keys).isSubset(of: allowed), value["schemaVersion"] as? Int == 1,
      let enabled = value["enabled"] as? Bool,
      let count = value["connectionCount"] as? Int, (0...1024).contains(count)
    else { throw AgentBridgeFailure.invalidReply }
    if enabled {
      guard let port = value["port"] as? Int, (1...65535).contains(port),
        let endpoint = value["wsEndpoint"] as? String,
        let components = URLComponents(string: endpoint), components.scheme == "ws",
        ["127.0.0.1", "::1"].contains(components.host ?? ""),
        components.port == port, components.user == nil, components.password == nil,
        components.query == nil, components.fragment == nil,
        components.path.hasPrefix("/devtools/browser/"),
        Self.isBrowserEndpointPath(components.path),
        endpoint.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":/.-_[]".contains($0)) }
        )
      else {
        throw AgentBridgeFailure.invalidReply
      }
      return Self(enabled: true, port: port, wsEndpoint: endpoint, connectionCount: count)
    }
    guard count == 0, value["port"] == nil || value["port"] as? Int == 0,
      value["wsEndpoint"] == nil
    else {
      throw AgentBridgeFailure.invalidReply
    }
    return .disabled
  }

  private static func isBrowserEndpointPath(_ path: String) -> Bool {
    let prefix = "/devtools/browser/"
    guard path.hasPrefix(prefix) else { return false }
    let identifier = path.dropFirst(prefix.count).utf8
    return (1...128).contains(identifier.count)
      && identifier.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
          || $0 == 45 || $0 == 95
      }
  }
}

@MainActor @Observable
final class AgentBridgeModel {
  typealias Reply = @MainActor ([String: Any]?, Error?) -> Void
  typealias Request = @MainActor (AgentBridgeOperation, SiteControlTarget, @escaping Reply) -> Void

  private(set) var target: SiteControlTarget
  private(set) var status = AgentBridgeStatus.disabled
  private(set) var busy = false
  private(set) var failure: String?
  private(set) var canCopySetup = false
  private(set) var revocationUnconfirmed = false
  @ObservationIgnored private var oneTimeToken: String?
  @ObservationIgnored private var grantOrigin: String?
  @ObservationIgnored private var pendingOrigin: String?
  @ObservationIgnored private var committedOrigin: String?
  @ObservationIgnored private let request: Request
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var statusRequestID: UUID?
  @ObservationIgnored private var closed = false
  @ObservationIgnored private var clipboardCleanupTask: Task<Void, Never>?

  var isConnected: Bool { status.connectionCount > 0 }
  var needsBanner: Bool { isConnected || revocationUnconfirmed }
  var hasOneTimeToken: Bool { canCopySetup }
  var connections: [AgentBridgeConnection] {
    guard status.enabled, status.connectionCount > 0 else { return [] }
    return (1...status.connectionCount).map { AgentBridgeConnection(index: $0) }
  }
  var documentedEndpoint: String? { status.enabled ? status.wsEndpoint : nil }
  var documentedInvocation: String? {
    documentedEndpoint.map(AgentBridgeSetup.invocation)
  }

  init(target: SiteControlTarget, request: @escaping Request) {
    self.target = target
    committedOrigin = target.origin
    self.request = request
  }

  func refresh() {
    guard !closed else { return }
    let current = revision
    let requestID = UUID()
    statusRequestID = requestID
    let currentTarget = target
    request(.status, currentTarget) { [weak self] result, error in
      guard let self, self.revision == current, self.statusRequestID == requestID else { return }
      self.statusRequestID = nil
      if let error {
        self.failure = error.localizedDescription
        return
      }
      do {
        let next = try AgentBridgeStatus.decode(result ?? [:])
        if next.enabled {
          self.status = next
          self.grantOrigin = self.target.origin
        } else {
          self.clear()
        }
        self.failure = nil
      } catch { self.failure = error.localizedDescription }
    }
  }

  func enable() {
    guard !closed, !busy, !status.enabled, !revocationUnconfirmed else { return }
    guard ["http", "https"].contains(target.url.scheme?.lowercased() ?? ""),
      target.origin != nil
    else {
      failure = ShellL10n.string("Agent control requires a web page.")
      return
    }
    busy = true
    failure = nil
    revision += 1
    let current = revision
    let currentTarget = target
    pendingOrigin = currentTarget.origin
    request(.enable, currentTarget) { [weak self] result, error in
      guard let self else { return }
      guard self.revision == current else {
        if error == nil {
          self.revoke(currentTarget)
        } else if self.revocationUnconfirmed {
          self.clear()
        }
        return
      }
      self.busy = false
      self.pendingOrigin = nil
      if let error {
        self.failure = error.localizedDescription
        return
      }
      self.acceptEnabled(result ?? [:])
      if !self.status.enabled { self.revoke(currentTarget) }
    }
  }

  func disable() {
    guard !closed, !busy, status.enabled || revocationUnconfirmed else { return }
    revoke(target)
  }

  func update(target next: SiteControlTarget, committed: Bool = false) {
    guard !closed else { return }
    let siteChanged =
      committed
      && (committedOrigin != next.origin || target.profileID != next.profileID
        || (grantOrigin != nil && grantOrigin != next.origin)
        || (pendingOrigin != nil && pendingOrigin != next.origin))
    if committed && siteChanged {
      let old = target
      let wasEnabled = status.enabled
      let wasPending = pendingOrigin != nil
      revision += 1
      oneTimeToken = nil
      canCopySetup = false
      pendingOrigin = nil
      if wasEnabled {
        revoke(old)
      } else if wasPending {
        revocationUnconfirmed = true
        busy = true
      }
    }
    if committed { committedOrigin = next.origin }
    target = next
  }

  func receive(enabled: Bool, connectionCount: Int) {
    guard !closed, status.enabled || revocationUnconfirmed,
      (0...1024).contains(connectionCount)
    else { return }
    if !enabled {
      clear()
      return
    }
    guard status.enabled else { return }
    status = AgentBridgeStatus(
      enabled: true, port: status.port, wsEndpoint: status.wsEndpoint,
      connectionCount: connectionCount)
  }

  func close() {
    guard !closed else { return }
    clipboardCleanupTask?.cancel()
    clipboardCleanupTask = nil
    let old = target
    let wasEnabled = status.enabled || revocationUnconfirmed
    clear()
    closed = true
    if wasEnabled { request(.disable, old) { _, _ in } }
  }

  enum Client { case claude, codex, cursor }

  func setupCommand(for client: Client) -> String? {
    guard let token = oneTimeToken, let endpoint = status.wsEndpoint else { return nil }
    let command = AgentBridgeSetup.command(for: client, endpoint: endpoint, token: token)
    guard !command.isEmpty else { return nil }
    return command
  }

  func copySetup(
    for client: Client, pasteboard: NSPasteboard = .general,
    clearAfter: Duration = .seconds(120)
  ) {
    guard let command = setupCommand(for: client) else { return }
    clipboardCleanupTask?.cancel()
    pasteboard.clearContents()
    pasteboard.setString(command, forType: .string)
    let changeCount = pasteboard.changeCount
    oneTimeToken = nil
    canCopySetup = false
    clipboardCleanupTask = Task { @MainActor [weak self, weak pasteboard] in
      do { try await Task.sleep(for: clearAfter) } catch { return }
      guard let self, !self.closed, let pasteboard,
        pasteboard.changeCount == changeCount
      else { return }
      pasteboard.clearContents()
      self.clipboardCleanupTask = nil
    }
  }

  private func acceptEnabled(_ result: [String: Any]) {
    let token = result["token"] as? String
    var publicResult = result
    publicResult.removeValue(forKey: "token")
    guard let token, token.count == 43,
      token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
      let decoded = try? AgentBridgeStatus.decode(publicResult), decoded.enabled
    else {
      failure = AgentBridgeFailure.invalidReply.localizedDescription
      return
    }
    status = decoded
    grantOrigin = target.origin
    oneTimeToken = token
    canCopySetup = true
    failure = nil
  }

  private func revoke(_ old: SiteControlTarget) {
    busy = true
    revocationUnconfirmed = true
    oneTimeToken = nil
    canCopySetup = false
    request(.disable, old) { [weak self] _, error in
      guard let self, !self.closed else { return }
      self.busy = false
      if let error {
        self.failure = error.localizedDescription
      } else {
        self.clear()
      }
    }
  }

  private func clear() {
    revision += 1
    status = .disabled
    grantOrigin = nil
    pendingOrigin = nil
    oneTimeToken = nil
    canCopySetup = false
    revocationUnconfirmed = false
    busy = false
  }

}
