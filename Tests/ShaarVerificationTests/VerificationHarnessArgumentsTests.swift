// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct VerificationHarnessArgumentsTests {
  @Test func launchRequiresFlagOutputPageAndBundledFrameworkDirectory() throws {
    let frameworks = URL(filePath: "/application/Contents/Frameworks")
    let args = ["--tab-adoption-smoke", "/tmp/report.json", "http://127.0.0.1:1234/", "extra"]
    let launch = try #require(
      VerificationHarnessArguments.launch(
        "--tab-adoption-smoke", arguments: args, frameworksURL: frameworks))
    #expect(
      launch.framework == frameworks.appending(path: "Chromium Framework.framework"))
    #expect(launch.output == URL(filePath: "/tmp/report.json"))
    #expect(launch.page == URL(string: "http://127.0.0.1:1234/"))
    #expect(launch.remainder == "extra")

    #expect(
      VerificationHarnessArguments.launch(
        "--passkey-availability", arguments: args, frameworksURL: frameworks) == nil)
    #expect(
      VerificationHarnessArguments.launch(
        "--tab-adoption-smoke", arguments: ["--tab-adoption-smoke", "report"],
        frameworksURL: frameworks) == nil)
    #expect(
      VerificationHarnessArguments.launch(
        "--tab-adoption-smoke",
        arguments: ["--tab-adoption-smoke", "first.json", "http://127.0.0.1:1234/",
          "--tab-adoption-smoke", "second.json"], frameworksURL: frameworks) == nil)
    #expect(
      VerificationHarnessArguments.launch(
        "--tab-adoption-smoke", arguments: args, frameworksURL: nil) == nil)
  }

  @Test func launchKeepsInvalidPageAsAnInvalidPageForTheProbeGuard() throws {
    let launch = try #require(
      VerificationHarnessArguments.launch(
        "--passkey-availability",
        arguments: ["--passkey-availability", "/tmp/report.json", "http://["],
        frameworksURL: URL(filePath: "/application/Frameworks")))
    #expect(launch.page == nil)
    #expect(launch.remainder == nil)
  }
}
