// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A private document is ready for the next command only after the engine has a document.
/// `started` is the provisional destination and must not unblock the following navigation.
enum PrivateNavigationReadiness {
  static let settledPhases: Set<String> = ["committed", "finished", "state"]

  static func hasSettled(
    url: String?,
    loading: Bool,
    phase: String?,
    contains expected: String
  ) -> Bool {
    guard let url, url.contains(expected) else { return false }
    if loading { return false }
    guard let phase else { return false }
    return settledPhases.contains(phase)
  }
}
