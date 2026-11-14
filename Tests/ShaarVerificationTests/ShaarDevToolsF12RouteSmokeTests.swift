// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("DevTools F12 route preflight")
struct ShaarDevToolsF12RouteSmokeTests {
  @Test func missingRouteArgumentsFailBeforeEngineStartup() {
    #expect(ShaarDevToolsF12RouteSmoke.run(arguments: []) == 2)
    #expect(ShaarDevToolsF12RouteSmoke.run(arguments: ["--devtools-f12-route"]) == 2)
    #expect(
      ShaarDevToolsF12RouteSmoke.run(arguments: ["--devtools-f12-route", "/tmp/report.json"]) == 2)
  }

  @Test func fixtureURLRequiresCredentialFreeHTTPOnAnExplicitLoopbackPort() throws {
    #expect(
      ShaarDevToolsF12RouteSmoke.isValidFixtureURL(URL(string: "http://127.0.0.1:43210/fixture")))

    for value in [
      "https://127.0.0.1:43210/fixture",
      "http://127.0.0.1/fixture",
      "http://localhost:43210/fixture",
      "http://192.0.2.1:43210/fixture",
      "http://user:secret@127.0.0.1:43210/fixture",
    ] {
      let url = try #require(URL(string: value))
      #expect(!ShaarDevToolsF12RouteSmoke.isValidFixtureURL(url), "\(value)")
    }
    #expect(!ShaarDevToolsF12RouteSmoke.isValidFixtureURL(nil))
  }
}
