// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite("Platform prompt probe preflight")
struct PlatformPromptProbeTests {
  @Test func missingRequiredArgumentsFailBeforeRuntimeStartup() {
    #expect(PlatformPromptProbe.run(arguments: []) == 1)
    #expect(PlatformPromptProbe.run(arguments: ["--probe-framework"]) == 1)
    #expect(
      PlatformPromptProbe.run(arguments: ["--probe-framework", "/tmp/missing-framework"]) == 1)
  }
}
