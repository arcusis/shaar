// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite struct WebsitePermissionPromptProbeTests {
  @Test func missingProbeArgumentsFailBeforeLaunch() {
    #expect(WebsitePermissionPromptProbe.run(arguments: ["--probe-website-permission"]) == 1)
  }

  @Test func passedRequiresTheFourWebsitePrompts() {
    let ready = WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [], promptedNames: ["media"])
    #expect(!ready)
    let complete = WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [],
      promptedNames: ["media", "geolocation", "notifications", "midi", "protocol"])
    #expect(complete)
  }
}
