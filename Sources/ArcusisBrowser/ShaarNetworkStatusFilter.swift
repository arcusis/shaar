// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
