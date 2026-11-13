// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct DevelopmentModeProbeTests {
  @Test func fixturePathsResolveAtTheServerRoot() {
    let account = URL(string: "http://127.0.0.1:43123/account")!
    #expect(
      DevelopmentModeProbe.fixtureURL(account, path: "devmode-next").path == "/devmode-next")
    #expect(
      DevelopmentModeProbe.fixtureURL(account, path: "devmode-vite").path == "/devmode-vite")
  }

  @Test func fixtureURLPreservesServerAuthorityAndDropsAccountQueryAndFragment() {
    let account = URL(string: "http://127.0.0.1:43123/nested/account?token=local#section")!
    #expect(
      DevelopmentModeProbe.fixtureURL(account, path: "devmode-next").absoluteString
        == "http://127.0.0.1:43123/nested/devmode-next")
  }
}
