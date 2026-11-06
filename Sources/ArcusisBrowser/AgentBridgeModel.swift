// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Observation

enum AgentBridgeFailure: LocalizedError {
  case invalidReply
  var errorDescription: String? { "The agent bridge returned an invalid reply." }
}

enum AgentBridgeOperation: Int {
  case enable = 1005
  case disable = 1006
  case status = 1007
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
        components.path.count > "/devtools/browser/".count,
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
  @ObservationIgnored private var closed = false

  var isConnected: Bool { status.connectionCount > 0 }
  var needsBanner: Bool { isConnected || revocationUnconfirmed }
  var hasOneTimeToken: Bool { canCopySetup }

  init(target: SiteControlTarget, request: @escaping Request) {
    self.target = target
    committedOrigin = target.origin
    self.request = request
  }

  func refresh() {
    guard !closed else { return }
    let current = revision
    let currentTarget = target
    request(.status, currentTarget) { [weak self] result, error in
      guard let self, self.revision == current else { return }
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
      failure = "Agent control requires a web page."
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
    let old = target
    let wasEnabled = status.enabled || revocationUnconfirmed
    clear()
    closed = true
    if wasEnabled { request(.disable, old) { _, _ in } }
  }

  enum Client { case claude, codex }

  func setupCommand(for client: Client) -> String? {
    guard let token = oneTimeToken, let endpoint = status.wsEndpoint else { return nil }
    let header = #"{"Authorization":"Bearer "# + token + #""}"#
    let arguments = "--wsEndpoint=\(endpoint) --wsHeaders='\(header)'"
    switch client {
    case .claude:
      return "claude mcp add shaar-agent -- npx -y chrome-devtools-mcp@latest \(arguments)"
    case .codex:
      return "codex mcp add shaar-agent -- npx -y chrome-devtools-mcp@latest \(arguments)"
    }
  }

  func copySetup(for client: Client) {
    guard let command = setupCommand(for: client) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    let changeCount = NSPasteboard.general.changeCount
    oneTimeToken = nil
    canCopySetup = false
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(120))
      if NSPasteboard.general.changeCount == changeCount {
        NSPasteboard.general.clearContents()
      }
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
