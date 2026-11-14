// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct EngineProbeFixtureURLTests {
  @Test func fixtureRequiresHTTPOnIPv4LoopbackAndAnUsablePort() {
    #expect(EngineProbeFixtureURL.isLoopback(URL(string: "http://127.0.0.1:43123/account")))
    #expect(!EngineProbeFixtureURL.isLoopback(nil))
    #expect(!EngineProbeFixtureURL.isLoopback(URL(string: "https://127.0.0.1:43123/account")))
    #expect(!EngineProbeFixtureURL.isLoopback(URL(string: "http://localhost:43123/account")))
    #expect(!EngineProbeFixtureURL.isLoopback(URL(string: "http://127.0.0.1/account")))
    #expect(!EngineProbeFixtureURL.isLoopback(URL(string: "http://127.0.0.1:0/account")))
  }
}
