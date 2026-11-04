// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Test func onboardingPopupCallbackRequiresMatchingOriginTypeAndNonce() {
  let valid: [String: Any] = [
    "origin": "http://127.0.0.1:4000",
    "type": "shaar-onboarding-callback",
    "token": "attempt-token",
  ]
  #expect(
    ProfileOnboardingPopupCallback.matches(
      valid, origin: "http://127.0.0.1:4000", token: "attempt-token"))
  #expect(
    !ProfileOnboardingPopupCallback.matches(
      valid, origin: "http://127.0.0.1:5000", token: "attempt-token"))
  #expect(
    !ProfileOnboardingPopupCallback.matches(
      valid.merging(["token": "stale-token"]) { _, new in new },
      origin: "http://127.0.0.1:4000", token: "attempt-token"))
  #expect(
    !ProfileOnboardingPopupCallback.matches(
      valid.merging(["type": "other-message"]) { _, new in new },
      origin: "http://127.0.0.1:4000", token: "attempt-token"))
  #expect(!ProfileOnboardingPopupCallback.matches(nil, origin: "", token: ""))
}
