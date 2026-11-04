// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

/// Hidden, disposable two-profile acceptance probe for a native Shaar engine.
/// The caller supplies already-open regular profile handles and a Web Store
/// extension that was approved and installed in the first profile.
struct SharedExtensionProbe {
  let adapter: ShaarExtensionsAdapter
  let home: ShaarExtensionHome
  let extensionID: String
  let approvedVersion: String
  let firstProfile: UUID
  let secondProfile: UUID

  func run() async throws -> [String] {
    try await requireInstalled(in: firstProfile)
    let result = try await home.recordApprovedInstall(
      extensionID, approvedVersion: approvedVersion,
      profileIDs: [firstProfile, secondProfile])
    guard result.failed.isEmpty else { throw Failure.installFailed }
    try await waitForInstall(in: secondProfile)
    try await adapter.manage(
      profileID: secondProfile, action: .setEnabled(extensionID, false))
    let first = try await extensionState(in: firstProfile)
    let second = try await extensionState(in: secondProfile)
    guard first?.enabled == true, second?.enabled == false else {
      throw Failure.enableStateLeaked
    }
    return [
      "one approved install reached two regular profiles",
      "disabling the second profile kept the first profile enabled",
    ]
  }

  private func requireInstalled(in profileID: UUID) async throws {
    guard let item = try await extensionState(in: profileID),
      item.version == approvedVersion
    else { throw Failure.approvedInstallMissing }
  }

  private func waitForInstall(in profileID: UUID) async throws {
    for _ in 0..<120 {
      if let item = try await extensionState(in: profileID) {
        guard item.version == approvedVersion else { throw Failure.wrongVersion }
        return
      }
      try await Task.sleep(for: .seconds(1))
    }
    throw Failure.installTimedOut
  }

  private func extensionState(in profileID: UUID) async throws -> ShaarExtensionSummary? {
    try await adapter.list(profileID: profileID).first { $0.id == extensionID }
  }

  enum Failure: Error {
    case approvedInstallMissing
    case installFailed
    case installTimedOut
    case wrongVersion
    case enableStateLeaked
  }
}
