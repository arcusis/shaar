// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum ProfileOnboardingPopupCallback {
  static func matches(_ reply: [String: Any]?, origin: String, token: String) -> Bool {
    reply?["origin"] as? String == origin
      && reply?["type"] as? String == "shaar-onboarding-callback"
      && reply?["token"] as? String == token
  }
}
