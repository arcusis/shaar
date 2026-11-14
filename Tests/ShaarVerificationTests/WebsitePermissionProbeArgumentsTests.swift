// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct WebsitePermissionProbeArgumentsTests {
  @Test func flagLookupRequiresAnExactFlagAndFollowingValue() {
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output", in: ["--probe-output", "/tmp/report.json"])
        == "/tmp/report.json")
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output", in: ["--probe-output"])
        == nil)
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output", in: ["--probe-output", "--probe-data-dir", "/tmp/probe"])
        == nil)
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output", in: ["--probe-output-other", "/tmp/report.json"])
        == nil)
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output", in: ["--probe-framework", "Framework"])
        == nil)
    #expect(
      WebsitePermissionProbeArguments.value(
        after: "--probe-output",
        in: ["--probe-output", "first", "--probe-output", "second"])
        == nil)
  }
}
