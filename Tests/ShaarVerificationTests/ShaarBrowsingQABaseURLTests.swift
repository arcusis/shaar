// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQABaseURLTests {
  @Test func fixtureURLRequiresAnExplicitPortAndNoCredentials() {
    #expect(ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "http://127.0.0.1:48123/")))
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "http://127.0.0.1/")))
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "http://127.0.0.1:0/")))
    #expect(
      !ShaarBrowsingQA.isLoopbackFixtureURL(
        URL(string: "http://user:secret@127.0.0.1:48123/")))
  }

  @Test func fixtureURLRejectsMissingAndNonLoopbackAddresses() {
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(nil))
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "https://127.0.0.1:48123/")))
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "http://localhost:48123/")))
    #expect(!ShaarBrowsingQA.isLoopbackFixtureURL(URL(string: "http://example.invalid:48123/")))
  }
}
