// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@MainActor
@Suite("Profile onboarding provider page evidence")
struct ProfileOnboardingProviderPageTests {
  @Test func emailEvidenceMustBeJSONBoolean() {
    let address = "https://accounts.google.com/signin"
    #expect(
      ProfileOnboardingProbe.providerPageIsReady(
        ["url": address, "ready": "complete", "email": true], provider: .google))

    for malformed in [
      ["url": address, "ready": "complete", "email": 1],
      ["url": address, "ready": "complete", "email": "true"],
      ["url": address, "ready": "complete"],
    ] as [[String: Any]] {
      #expect(
        !ProfileOnboardingProbe.providerPageIsReady(malformed, provider: .google))
    }
  }
}
