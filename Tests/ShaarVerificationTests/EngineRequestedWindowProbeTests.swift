// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite("Engine requested-window report identity")
struct EngineRequestedWindowProbeTests {
  @Test func workerReportMustCarryTheExpectedTokenAsAString() {
    #expect(
      EngineRequestedWindowProbe.matchesWorkerReport(
        ["token": "current", "windowID": 7], token: "current"))
    #expect(!EngineRequestedWindowProbe.matchesWorkerReport(["token": "stale"], token: "current"))
    #expect(!EngineRequestedWindowProbe.matchesWorkerReport([:], token: "current"))
    #expect(!EngineRequestedWindowProbe.matchesWorkerReport(["token": 7], token: "current"))
  }
}
