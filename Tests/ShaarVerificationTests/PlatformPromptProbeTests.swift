// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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

  @Test func pageURLMustBeAnUnauthenticatedLoopbackHTTPFixtureWithAValidPort() {
    #expect(
      PlatformPromptProbeConfiguration.acceptsPageURL(
        URL(string: "http://127.0.0.1:43210/screen")))
    for value in [
      "https://127.0.0.1:43210/screen",
      "http://localhost:43210/screen",
      "http://example.invalid:43210/screen",
      "http://127.0.0.1:0/screen",
      "http://user:secret@127.0.0.1:43210/screen",
    ] {
      #expect(!PlatformPromptProbeConfiguration.acceptsPageURL(URL(string: value)))
    }
    #expect(!PlatformPromptProbeConfiguration.acceptsPageURL(nil))
  }
}
