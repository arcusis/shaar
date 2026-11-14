// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ExternalAppConsentEvidenceTests {
  private func completeEvidence() -> ExternalAppConsentProbe.Evidence {
    var evidence = ExternalAppConsentProbe.Evidence(runID: "fixture-run")
    evidence.checks = Array(repeating: true, count: ExternalAppConsentProbe.checkNames.count)
    evidence.approvedRequests = 2
    evidence.launchCount = 2
    evidence.deniedRequests = 6
    evidence.cleanup = ["passed": true]
    return evidence
  }

  @Test func completionRequiresAllChecksAndExactRequestCounts() {
    #expect(ExternalAppConsentProbe.isComplete(completeEvidence()))
    for index in ExternalAppConsentProbe.checkNames.indices {
      var incomplete = completeEvidence()
      incomplete.checks[index] = false
      #expect(!ExternalAppConsentProbe.isComplete(incomplete))
    }
    for (key, count) in [("approved", 1), ("launch", 1), ("denied", 5)] {
      var incomplete = completeEvidence()
      switch key {
      case "approved": incomplete.approvedRequests = count
      case "launch": incomplete.launchCount = count
      default: incomplete.deniedRequests = count
      }
      #expect(!ExternalAppConsentProbe.isComplete(incomplete))
    }
  }

  @Test func cleanupPassMustBeExplicitJSONBoolean() {
    for value: Any? in [nil, false, 1, "true"] {
      var incomplete = completeEvidence()
      incomplete.cleanup["passed"] = value
      #expect(!ExternalAppConsentProbe.isComplete(incomplete))
    }
  }

  @Test func approvalsAndLaunchesRejectExcessWhileDenialsAllowExtraAttempts() {
    var tooManyApprovals = completeEvidence()
    tooManyApprovals.approvedRequests = 3
    #expect(!ExternalAppConsentProbe.isComplete(tooManyApprovals))

    var tooManyLaunches = completeEvidence()
    tooManyLaunches.launchCount = 3
    #expect(!ExternalAppConsentProbe.isComplete(tooManyLaunches))

    var extraDenials = completeEvidence()
    extraDenials.deniedRequests = 7
    #expect(ExternalAppConsentProbe.isComplete(extraDenials))
  }
}
