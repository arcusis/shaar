// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Passkey availability preflight")
struct ShaarPasskeyAvailabilitySmokeTests {
  @Test func pageURLMustBeUnauthenticatedLoopbackHTTP() {
    #expect(
      ShaarPasskeyAvailabilitySmoke.acceptsPageURL(
        URL(string: "http://127.0.0.1:8080/passkeys")!))

    for value in [
      "https://127.0.0.1:8080/passkeys",
      "http://localhost:8080/passkeys",
      "http://user@127.0.0.1:8080/passkeys",
      "http://user:secret@127.0.0.1:8080/passkeys",
    ] {
      #expect(!ShaarPasskeyAvailabilitySmoke.acceptsPageURL(URL(string: value)!))
    }
  }
}
