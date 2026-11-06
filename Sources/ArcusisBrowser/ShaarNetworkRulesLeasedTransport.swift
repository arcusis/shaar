// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

/// Binds rule application to a panel lease owned by the live DevTools stream.
@MainActor struct ShaarNetworkRulesLeasedTransport: ShaarNetworkRulesTransport {
  let adapter: ShaarDevToolsAdapter
  let leaseID: UInt32
  let scope: ShaarNavigationScope
  let windowID: String
  let tabID: String
  let target: SiteControlTarget

  var available: Bool {
    leaseID > 0 && UUID(uuidString: scope.profileID) == target.profileID
      && UUID(uuidString: tabID) == target.tabID && UUID(uuidString: windowID) != nil
  }

  func apply(_ rules: [ShaarResolvedNetworkRule], to requested: SiteControlTarget) async throws {
    guard available, requested == target else { throw ShaarNetworkRuleError.unavailable }
    let actions = rules.map(Self.action)
    try await withCheckedThrowingContinuation { continuation in
      do {
        _ = try adapter.setPanelNetworkRules(
          actions, leaseID: leaseID, scope: scope, windowID: windowID, tabID: tabID
        ) { result in
          switch result {
          case .success: continuation.resume()
          case .failure(let error): continuation.resume(throwing: error)
          }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private static func action(_ rule: ShaarResolvedNetworkRule) -> ShaarDevToolsNetworkRule {
    let kind: ShaarDevToolsNetworkRuleKind
    switch rule.kind {
    case .mock: kind = .mock
    case .redirect: kind = .redirect
    case .delay: kind = .delay
    case .requestHeaders: kind = .requestHeaders
    case .responseHeaders: kind = .responseHeaders
    }
    return ShaarDevToolsNetworkRule(
      method: rule.method, url: rule.url, kind: kind, status: rule.status,
      headers: rule.headers.map { .init(name: $0.name, value: $0.value) },
      bodyBase64: rule.bodyBase64 ?? "", redirectURL: rule.redirectURL,
      delayMilliseconds: rule.delayMilliseconds)
  }
}
