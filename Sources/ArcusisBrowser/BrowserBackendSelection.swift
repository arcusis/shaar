// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum BrowserBackendSelection: Equatable {
  case ardia
  case shaar

  static func choose(environment: [String: String], arguments: [String]) -> Self {
    if arguments.contains("--shaar-engine-backend=shaar") { return .shaar }
    if environment["SHAAR_ENGINE_BACKEND"] == "shaar" { return .shaar }
    return .ardia
  }
}
