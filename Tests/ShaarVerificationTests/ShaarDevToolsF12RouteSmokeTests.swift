// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
}
