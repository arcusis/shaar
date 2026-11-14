// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct SiteControlsProbeFixtureTests {
  @Test func siteControlsURLUsesItsOwnHostAndDropsFixturePathAndQuery() throws {
    let fixture = try #require(URL(string: "http://127.0.0.1:43210/other?account=alpha"))

    let result = try #require(SiteControlsProbeFixture.url(from: fixture))
    let components = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "http")
    #expect(components.host == "site-controls.localhost")
    #expect(components.port == 43210)
    #expect(components.path == "/site-controls")
    #expect(components.query == nil)
  }
}
