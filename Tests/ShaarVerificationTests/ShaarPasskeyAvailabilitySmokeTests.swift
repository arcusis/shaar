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

@MainActor
@Suite("Passkey availability report")
struct ShaarPasskeyAvailabilityReportTests {
  private let availableAPIs: [String: Any] = [
    "passkey": "false",
    "publicKeyCredential": true,
    "platformAuthenticator": true,
    "conditionalMediation": true,
    "credentialsGet": true,
    "secureContext": true,
  ]

  @Test func passesOnlyWhenPlatformAuthenticatorIsUnavailableInAQuietSecurePage() {
    let report = ShaarPasskeyAvailabilitySmoke.availabilityReport(
      state: availableAPIs, quiet: true)

    #expect(report["passed"] as? Bool == true)
    #expect(report["passkey"] as? String == "false")
    #expect(report["rendererQuiet"] as? Bool == true)
  }

  @Test func rejectsUnexpectedPasskeyAvailabilityAndMissingPrerequisites() {
    for (key, value) in [
      ("passkey", "true"),
      ("publicKeyCredential", "missing"),
      ("platformAuthenticator", false),
      ("credentialsGet", false),
      ("secureContext", false),
    ] as [(String, Any)] {
      var state = availableAPIs
      state[key] = value
      #expect(
        ShaarPasskeyAvailabilitySmoke.availabilityReport(state: state, quiet: true)["passed"]
          as? Bool == false)
    }

    #expect(
      ShaarPasskeyAvailabilitySmoke.availabilityReport(state: availableAPIs, quiet: false)["passed"]
        as? Bool == false)
  }
}
