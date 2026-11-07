// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarNetworkThrottle: String, CaseIterable, Sendable {
  case none = "No throttling"
  case fast3G = "Fast 3G"
  case slow3G = "Slow 3G"
  case offline = "Offline"

  var parameters: [String: Any] {
    switch self {
    case .none:
      return Self.payload(offline: false, latency: 0, download: -1, upload: -1)
    case .fast3G:
      return Self.payload(offline: false, latency: 150, download: 200_000, upload: 93_750)
    case .slow3G:
      return Self.payload(offline: false, latency: 400, download: 50_000, upload: 50_000)
    case .offline:
      return Self.payload(offline: true, latency: 0, download: -1, upload: -1)
    }
  }

  private static func payload(
    offline: Bool, latency: Int, download: Int, upload: Int
  ) -> [String: Any] {
    [
      "offline": offline,
      "latency": latency,
      "downloadThroughput": download,
      "uploadThroughput": upload,
    ]
  }
}

enum ShaarNetworkStatusFilter: String, CaseIterable, Sendable {
  case any = "Any status"
  case success = "2xx"
  case redirect = "3xx"
  case clientError = "4xx"
  case serverError = "5xx"
  case failed = "Failed"

  func matches(_ row: ShaarNetworkRequest) -> Bool {
    switch self {
    case .any:
      return true
    case .failed:
      return row.failure != nil
    case .success:
      return Self.classDigit(row.status) == 2
    case .redirect:
      return Self.classDigit(row.status) == 3
    case .clientError:
      return Self.classDigit(row.status) == 4
    case .serverError:
      return Self.classDigit(row.status) == 5
    }
  }

  private static func classDigit(_ status: Int?) -> Int? {
    guard let status, (100..<600).contains(status) else { return nil }
    return status / 100
  }
}

@MainActor @Observable
final class ShaarNetworkConditionsModel {
  var throttle = ShaarNetworkThrottle.none
  var cacheDisabled = false
  private(set) var failure: String?
  @ObservationIgnored var applyThrottle: (@MainActor (ShaarNetworkThrottle) async throws -> Void)?
  @ObservationIgnored var applyCacheDisabled: (@MainActor (Bool) async throws -> Void)?

  func select(_ next: ShaarNetworkThrottle) async {
    let previous = throttle
    throttle = next
    guard let applyThrottle else { return }
    do {
      try await applyThrottle(next)
      failure = nil
    } catch {
      throttle = previous
      failure = error.localizedDescription
    }
  }

  func setCacheDisabled(_ disabled: Bool) async {
    let previous = cacheDisabled
    cacheDisabled = disabled
    guard let applyCacheDisabled else { return }
    do {
      try await applyCacheDisabled(disabled)
      failure = nil
    } catch {
      cacheDisabled = previous
      failure = error.localizedDescription
    }
  }
}

enum ShaarNetworkConditions {
  static func applyThrottle(
    _ throttle: ShaarNetworkThrottle,
    call: @MainActor (String, [String: Any]) async throws -> Void
  ) async throws {
    try await call("Network.enable", [:])
    try await call("Network.emulateNetworkConditions", throttle.parameters)
  }

  static func applyCacheDisabled(
    _ disabled: Bool,
    call: @MainActor (String, [String: Any]) async throws -> Void
  ) async throws {
    try await call("Network.enable", [:])
    try await call("Network.setCacheDisabled", ["cacheDisabled": disabled])
  }
}
