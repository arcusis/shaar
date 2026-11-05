// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ProfileAccountSignInWindowTests {
  @Test func failedSignInInitializationClosesNativeWindow() {
    let runtime = SignInWindowCreationRuntime()

    #expect(throws: (any Error).self) {
      try ProfileAccountSignIn(
        events: BrowserRuntimeEvents(runtime: runtime), profile: BrowserProfile(name: "Test"),
        provider: .google, purpose: .signIn, visible: false)
    }
    #expect(runtime.createdIDs.count == 1)
    #expect(runtime.closedIDs == runtime.createdIDs)
  }
}

private final class SignInWindowCreationRuntime: ARCChromiumRuntime {
  var createdIDs: [String] = []
  var closedIDs: [String] = []

  override func createWindowID(_ windowID: String) throws {
    createdIDs.append(windowID)
  }

  override func closeWindowID(_ windowID: String) -> Bool {
    closedIDs.append(windowID)
    return true
  }
}
