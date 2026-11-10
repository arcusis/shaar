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
}
