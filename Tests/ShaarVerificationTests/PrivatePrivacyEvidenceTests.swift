// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PrivatePrivacyEvidenceTests {
  @Test func preferencesRequireBothPrivateDenialAndNormalPositiveControl() {
    let keys = [
      "credentials_enable_service", "autofill.profile_enabled", "autofill.credit_card_enabled",
    ]
    var observations: [String: Any] = Dictionary(
      uniqueKeysWithValues: keys.map { ($0, ["private": false, "normal": true]) })
    observations["wildcardCookieSetting"] = ["error": "origin must be an http(s) origin"]
    #expect(PrivatePrivacyEvidence.preferences(observations).values.allSatisfy { $0 })
    for key in keys {
      for invalid: Any in ["false", ["normal": true], ["private": true, "normal": false]] {
        var changed = observations
        changed[key] = invalid
        #expect(
          PrivatePrivacyEvidence.preferences(changed)["privateAutofillAndPasswordSavingOff"]
            == false)
      }
      var changed = observations
      changed[key] = ["private": false]
      #expect(
        PrivatePrivacyEvidence.preferences(changed)["normalAutofillPreferencesUnchanged"] == false)
    }
    observations["wildcardCookieSetting"] = ["error": "unrelated failure"]
    #expect(
      PrivatePrivacyEvidence.preferences(observations)["wildcardCookieDefaultUnavailable"] == false)
    #expect(PrivatePrivacyEvidence.preferences([:]).values.allSatisfy { !$0 })
  }

  @Test func storageRequiresEveryExplicitObservationInBothAllowAndRevokePhases() {
    for allowed in [false, true] {
      let observations: [String: Any] = Dictionary(
        uniqueKeysWithValues: ["cookie", "local", "session", "indexedDB"].map { ($0, allowed) })
      #expect(
        PrivatePrivacyEvidence.storage(observations, allowed: allowed, includesIndexedDB: true))
      for key in observations.keys {
        var changed = observations
        changed.removeValue(forKey: key)
        #expect(!PrivatePrivacyEvidence.storage(changed, allowed: allowed, includesIndexedDB: true))
        changed[key] = !allowed
        #expect(!PrivatePrivacyEvidence.storage(changed, allowed: allowed, includesIndexedDB: true))
        changed[key] = "unavailable"
        #expect(!PrivatePrivacyEvidence.storage(changed, allowed: allowed, includesIndexedDB: true))
      }
      var withoutIndexedDB = observations
      withoutIndexedDB.removeValue(forKey: "indexedDB")
      #expect(
        PrivatePrivacyEvidence.storage(withoutIndexedDB, allowed: allowed, includesIndexedDB: false)
      )
    }
    #expect(!PrivatePrivacyEvidence.storage([:], allowed: false, includesIndexedDB: false))
  }

  @Test func permissionsRequireDeniedQueriesAndRejectedRealRequests() {
    let observations: [String: Any] = [
      "camera": "denied", "microphone": "denied", "geolocation": "denied",
      "notifications": "denied",
      "cameraRequest": "NotAllowedError", "microphoneRequest": "NotAllowedError",
      "locationRequest": 1, "notificationRequest": "denied",
    ]
    #expect(PrivatePrivacyEvidence.permissions(observations).values.allSatisfy { $0 })
    for key in observations.keys {
      var changed = observations
      changed.removeValue(forKey: key)
      #expect(PrivatePrivacyEvidence.permissions(changed).values.contains(false))
      changed[key] = "granted"
      #expect(PrivatePrivacyEvidence.permissions(changed).values.contains(false))
    }
    var timeout = observations
    timeout["locationRequest"] = 3
    #expect(
      PrivatePrivacyEvidence.permissions(timeout)["privatePermissionRequestsRejected"] == false)
    #expect(PrivatePrivacyEvidence.permissions([:]).values.allSatisfy { !$0 })
  }
}
