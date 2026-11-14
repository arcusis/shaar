// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite
struct NativeHostProbeTests {
  @Test func closedWindowRecoveryEvidenceRequiresAReopenedLiveSelectedPage() throws {
    let closed = UUID()
    let restored = UUID()
    let expectedURL = "http://127.0.0.1:49152/host-second-temporary"
    let evidence = NativeHostClosedWindowRecoveryEvidence(
      closedWindowID: closed, restoredWindowID: restored,
      closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
      selectedURL: expectedURL, expectedURL: expectedURL,
      selectedTabWasLive: true, recoverySnapshotWasConsumed: true)

    #expect(evidence.passed)
    let encoded = try JSONEncoder().encode(evidence)
    #expect(try JSONDecoder().decode(NativeHostClosedWindowRecoveryEvidence.self, from: encoded) == evidence)
  }

  @Test func closedWindowRecoveryEvidenceRejectsMissingReopenBehavior() {
    let closed = UUID()
    let expectedURL = "http://127.0.0.1:49152/host-second-temporary"

    #expect(
      !NativeHostClosedWindowRecoveryEvidence(
        closedWindowID: closed, restoredWindowID: closed,
        closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
        selectedURL: expectedURL, expectedURL: expectedURL,
        selectedTabWasLive: true, recoverySnapshotWasConsumed: true).passed)
    #expect(
      !NativeHostClosedWindowRecoveryEvidence(
        closedWindowID: closed, restoredWindowID: UUID(),
        closedWindowWasRemoved: true, reopenCommandWasEnabled: false,
        selectedURL: expectedURL, expectedURL: expectedURL,
        selectedTabWasLive: true, recoverySnapshotWasConsumed: true).passed)
    #expect(
      !NativeHostClosedWindowRecoveryEvidence(
        closedWindowID: closed, restoredWindowID: UUID(),
        closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
        selectedURL: "http://127.0.0.1:49152/wrong-page", expectedURL: expectedURL,
        selectedTabWasLive: true, recoverySnapshotWasConsumed: true).passed)
    #expect(
      !NativeHostClosedWindowRecoveryEvidence(
        closedWindowID: closed, restoredWindowID: UUID(),
        closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
        selectedURL: expectedURL, expectedURL: expectedURL,
        selectedTabWasLive: false, recoverySnapshotWasConsumed: true).passed)
    #expect(
      !NativeHostClosedWindowRecoveryEvidence(
        closedWindowID: closed, restoredWindowID: UUID(),
        closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
        selectedURL: expectedURL, expectedURL: expectedURL,
        selectedTabWasLive: true, recoverySnapshotWasConsumed: false).passed)
  }
}
