// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite
struct NativeHostProbeTests {
  @Test func closedWindowOnlyModeStopsAfterItsRecoveryEvidence() {
    #expect(
      NativeHostProbeScope.stopsAfterClosedWindowRecovery(
        environment: ["SHAAR_CLOSED_WINDOW_REOPEN_ONLY": "1"]))
    #expect(
      !NativeHostProbeScope.stopsAfterClosedWindowRecovery(
        environment: ["SHAAR_CLOSED_WINDOW_REOPEN_ONLY": "0"]))
    #expect(!NativeHostProbeScope.stopsAfterClosedWindowRecovery(environment: [:]))
  }

  @Test func closedWindowRecoveryEvidenceRequiresAReopenedLiveSelectedPage() throws {
    let closed = UUID()
    let restored = UUID()
    let fixture = try #require(URL(string: "http://127.0.0.1:49152/account"))
    let expectedURL = NativeHostClosedWindowRecoveryEvidence.expectedReopenedPage(
      fixture: fixture).absoluteString
    let evidence = NativeHostClosedWindowRecoveryEvidence(
      closedWindowID: closed, restoredWindowID: restored,
      closedWindowWasRemoved: true, reopenCommandWasEnabled: true,
      selectedURL: expectedURL, expectedURL: expectedURL,
      selectedTabWasLive: true, recoverySnapshotWasConsumed: true)

    #expect(evidence.passed)
    let encoded = try JSONEncoder().encode(evidence)
    #expect(try JSONDecoder().decode(NativeHostClosedWindowRecoveryEvidence.self, from: encoded) == evidence)
  }

  @Test func closedWindowReopensTheMostRecentlyNavigatedSelectedPage() throws {
    let fixture = try #require(URL(string: "http://127.0.0.1:49152/account"))
    #expect(
      NativeHostClosedWindowRecoveryEvidence.expectedReopenedPage(fixture: fixture)
        == URL(string: "http://127.0.0.1:49152/account/host-second-navigation-target"))
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
