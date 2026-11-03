// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Gates quit-time workspace snapshots on the host identity checkpoint the fixture needs.
struct NativeHostQuitReadiness {
  private(set) var identityCheckpointReady = false

  var canPrepareQuitSnapshot: Bool { identityCheckpointReady }

  mutating func markIdentityCheckpointReady() {
    identityCheckpointReady = true
  }
}
