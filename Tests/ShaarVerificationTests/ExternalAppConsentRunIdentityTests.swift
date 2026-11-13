// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ExternalAppConsentRunIdentityTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "external-app-run-identity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  @Test func initialPhaseWritesAnIdentityAcceptedByRestart() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }

    let initial = try ExternalAppConsentProbe.loadRunIdentity(root: root, phase: "initial")
    #expect(UUID(uuidString: initial.runID)?.uuidString == initial.runID)

    let initialEvidence = root.appending(path: "initial-external-app-consent.json")
    try JSONSerialization.data(withJSONObject: ["runID": initial.runID]).write(to: initialEvidence)
    let restarted = try ExternalAppConsentProbe.loadRunIdentity(root: root, phase: "restart")
    #expect(restarted.runID == initial.runID)
  }

  @Test func restartRejectsBooleanSchemaAndExtraMetadata() throws {
    for metadata: [String: Any] in [
      ["schema": true, "runID": UUID().uuidString.uppercased()],
      ["schema": 1, "runID": UUID().uuidString.uppercased(), "extra": "ignored"],
    ] {
      let root = try root()
      defer { try? FileManager.default.removeItem(at: root) }
      try JSONSerialization.data(withJSONObject: metadata).write(
        to: root.appending(path: "external-app-consent-run.json"))
      #expect(throws: (any Error).self) {
        try ExternalAppConsentProbe.loadRunIdentity(root: root, phase: "restart")
      }
    }
  }

  @Test func restartRequiresTheInitialEvidenceToMatchTheRunIdentity() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let runID = UUID().uuidString.uppercased()
    try JSONSerialization.data(withJSONObject: ["schema": 1, "runID": runID]).write(
      to: root.appending(path: "external-app-consent-run.json"))
    try JSONSerialization.data(withJSONObject: ["runID": UUID().uuidString.uppercased()]).write(
      to: root.appending(path: "initial-external-app-consent.json"))

    #expect(throws: (any Error).self) {
      try ExternalAppConsentProbe.loadRunIdentity(root: root, phase: "restart")
    }
  }
}
