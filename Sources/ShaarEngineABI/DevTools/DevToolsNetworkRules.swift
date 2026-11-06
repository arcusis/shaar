// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarDevToolsNetworkRuleKind: String, Sendable {
  case mock, redirect, delay, requestHeaders, responseHeaders
}

public struct ShaarDevToolsNetworkHeader: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }

  fileprivate var valid: Bool {
    let punctuation = "!#$%&'*+-.^_`|~".utf8
    let bytes = name.utf8
    return !bytes.isEmpty && bytes.count <= 128 && value.utf8.count <= 4_096
      && !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
      && bytes.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte)
          || (97...122).contains(byte) || punctuation.contains(byte)
      }
  }
}

/// A fixed action sent to the tab-scoped Fetch lease. Body files are resolved by the app.
public struct ShaarDevToolsNetworkRule: Equatable, Sendable {
  public let method: String
  public let url: String
  public let kind: ShaarDevToolsNetworkRuleKind
  public let status: Int
  public let headers: [ShaarDevToolsNetworkHeader]
  public let bodyBase64: String
  public let redirectURL: String
  public let delayMilliseconds: Int

  public init(
    method: String, url: String, kind: ShaarDevToolsNetworkRuleKind,
    status: Int = 200, headers: [ShaarDevToolsNetworkHeader] = [],
    bodyBase64: String = "", redirectURL: String = "", delayMilliseconds: Int = 0
  ) {
    self.method = method
    self.url = url
    self.kind = kind
    self.status = status
    self.headers = headers
    self.bodyBase64 = bodyBase64
    self.redirectURL = redirectURL
    self.delayMilliseconds = delayMilliseconds
  }

  var parameters: [String: Any]? {
    guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method),
      Self.validURL(url), (100...599).contains(status),
      (0...30_000).contains(delayMilliseconds),
      headers.count <= 32, headers.allSatisfy(\.valid),
      kind == .delay || delayMilliseconds == 0,
      kind == .redirect ? Self.validURL(redirectURL) : redirectURL.isEmpty,
      kind == .mock ? Self.validBody(bodyBase64) : bodyBase64.isEmpty,
      (kind != .requestHeaders && kind != .responseHeaders) || !headers.isEmpty
    else { return nil }
    return [
      "method": method, "url": url, "kind": kind.rawValue, "status": status,
      "headers": headers.map { ["name": $0.name, "value": $0.value] },
      "bodyBase64": bodyBase64, "redirectURL": redirectURL,
      "delayMilliseconds": delayMilliseconds,
    ]
  }

  private static func validBody(_ encoded: String) -> Bool {
    guard encoded.utf8.count <= 1_398_104,
      let body = Data(base64Encoded: encoded), body.count <= 1_048_576
    else { return false }
    return body.base64EncodedString() == encoded
  }

  private static func validURL(_ value: String) -> Bool {
    guard value.utf8.count <= 4_096,
      let parts = URLComponents(string: value),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.fragment == nil
    else { return false }
    guard let port = parts.port else { return true }
    return (1...65_535).contains(port)
  }
}

extension Array where Element == ShaarDevToolsNetworkRule {
  var networkRuleParameters: [[String: Any]]? {
    guard count <= 32 else { return nil }
    var result: [[String: Any]] = []
    result.reserveCapacity(count)
    for rule in self {
      guard let parameters = rule.parameters else { return nil }
      result.append(parameters)
    }
    return result
  }
}
