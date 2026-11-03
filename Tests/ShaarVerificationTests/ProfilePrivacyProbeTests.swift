// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor
struct ProfilePrivacyProbeTests {
  @Test func missingEngineFailsBeforeCreatingAnyFixturePages() async {
    let runtime = ARCChromiumRuntime()
    let probe = ProfilePrivacyProbe(
      runtime: runtime, fixture: URL(string: "http://localhost:12345/fixture")!)
    await #expect(throws: (any Error).self) { try await probe.run() }
  }
}
