// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PlatformPromptProbeArgumentsTests {
  @Test func valuesRequireAnExactFlagAndRejectTheNextOptionAsItsValue() {
    #expect(
      PlatformPromptProbeArguments.value(
        after: "--probe-output", in: ["--probe-output", "/tmp/report.json"])
        == "/tmp/report.json")
    #expect(
      PlatformPromptProbeArguments.value(after: "--probe-output", in: ["--probe-output"]) == nil)
    #expect(
      PlatformPromptProbeArguments.value(
        after: "--probe-output", in: ["--probe-output", "--probe-url", "http://127.0.0.1"])
        == nil)
    #expect(
      PlatformPromptProbeArguments.value(
        after: "--probe-output", in: ["--probe-output-other", "/tmp/report.json"]) == nil)
    #expect(
      PlatformPromptProbeArguments.value(
        after: "--probe-output", in: ["--probe-output", "first", "--probe-output", "second"])
        == nil)
  }
}
