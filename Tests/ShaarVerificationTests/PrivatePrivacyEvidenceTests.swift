// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ChromiumBridgeVerification
import ShaarEngineC
import Testing

@testable import ShaarVerification

@Suite struct PrivatePrivacyEvidenceTests {
  @Test func permissionPresentationRequiresTemporaryRendererVisibilityAndHiddenWindows() {
    let observations: [String: Any] = [
      "before": "hidden", "during": "visible", "completion": "visible", "after": "hidden",
      "nativeWindowsHiddenBefore": true, "nativeWindowsHiddenAfter": true,
    ]
    #expect(PrivatePrivacyEvidence.permissionPresentation(observations).values.allSatisfy { $0 })
    for key in observations.keys {
      var missing = observations
      missing.removeValue(forKey: key)
      #expect(PrivatePrivacyEvidence.permissionPresentation(missing).values.contains(false))
      var wrong = observations
      wrong[key] = false
      #expect(PrivatePrivacyEvidence.permissionPresentation(wrong).values.contains(false))
    }
  }

  @Test func nativePreferencesPreserveBothControlsAndWildcardRejection() {
    let keys = [
      "credentials_enable_service", "autofill.profile_enabled", "autofill.credit_card_enabled",
    ]
    var status: [String: Any] = [:]
    for key in keys {
      status[key + "Normal"] = true
      status[key + "Private"] = false
    }
    let rejected = Int(SHAAR_INVALID_ARGUMENT.rawValue)
    let observations = ARCProbePrivatePrivacyPreferences(status, rejected)
    #expect(PrivatePrivacyEvidence.preferences(observations).values.allSatisfy { $0 })
    for key in status.keys {
      var missing = status
      missing.removeValue(forKey: key)
      #expect(
        PrivatePrivacyEvidence.preferences(ARCProbePrivatePrivacyPreferences(missing, rejected))
          .values.contains(false))
      var inverted = status
      inverted[key] = !(status[key] as! Bool)
      #expect(
        PrivatePrivacyEvidence.preferences(ARCProbePrivatePrivacyPreferences(inverted, rejected))
          .values.contains(false))
    }
    for code in [SHAAR_OK, SHAAR_NOT_FOUND] {
      #expect(
        PrivatePrivacyEvidence.preferences(
          ARCProbePrivatePrivacyPreferences(status, Int(code.rawValue)))[
            "wildcardCookieDefaultUnavailable"] == false)
    }
  }

  @Test func engineStatusRequiresEveryPrivatePolicy() {
    let status: [AnyHashable: Any] = [
      "offTheRecord": true, "globalCookies": "block", "httpsOnly": true,
      "referrersEnabled": false, "webRTCIPHandlingPolicy": "disable_non_proxied_udp",
      "webRTCPolicyExceptionCount": 0, "localIPExceptionCount": 0,
      "extensionsDisabled": true, "trackerProtectionEnabled": true,
      "trackerDomainCount": 6913, "trackerRulesRevision": "domain-rules-v1",
    ]
    #expect(PrivatePrivacyEvidence.engineStatus(status).values.allSatisfy { $0 })
    for key in status.keys {
      var changed = status
      changed.removeValue(forKey: key)
      #expect(PrivatePrivacyEvidence.engineStatus(changed).values.contains(false))
    }
    #expect(PrivatePrivacyEvidence.engineStatus([:]).values.allSatisfy { !$0 })
  }

  @Test func nativeQuitRetainsCDPHoldUntilDialogCancellationSucceeds() {
    var held = true
    var releases = 0
    var rejections = 0
    let release = {
      held = false
      releases += 1
    }
    let reject = { rejections += 1 }
    ARCCompletePrivateQuitDialogCancellation(true, "No dialog is showing", release, reject)
    #expect(held && releases == 0 && rejections == 1)
    ARCCompletePrivateQuitDialogCancellation(false, nil, release, reject)
    #expect(held && releases == 0 && rejections == 2)
    ARCCompletePrivateQuitDialogCancellation(true, nil, release, reject)
    #expect(!held && releases == 1 && rejections == 2)
  }

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

  @Test func quitHoldRejectsAnUnknownDevToolsCommandBeforeArming() {
    #expect(ARCProbeDevToolsCommandIsUnknown("unknown DevTools capability or command"))
    #expect(!ARCProbeDevToolsCommandIsUnknown("No dialog is showing"))
    #expect(!ARCProbeDevToolsCommandIsUnknown("protocol command failed"))
    #expect(!ARCProbeDevToolsCommandIsUnknown(""))
  }

  @Test func quitHoldRequiresALoopbackDocument() {
    #expect(ARCProbeLoopbackDocumentURL("http://127.0.0.1:49195/account"))
    #expect(ARCProbeLoopbackDocumentURL("http://localhost/fixture"))
    #expect(!ARCProbeLoopbackDocumentURL("https://127.0.0.1/account"))
    #expect(!ARCProbeLoopbackDocumentURL("http://example.com/"))
    #expect(!ARCProbeLoopbackDocumentURL("about:blank"))
    #expect(!ARCProbeLoopbackDocumentURL(""))
  }

  @Test func quitDialogResultNamesTheEngineOutcome() {
    #expect(ARCProbePrivateQuitDialogResult(true, nil) == "cancelled")
    #expect(ARCProbePrivateQuitDialogResult(false, nil) == "owner-stale")
    #expect(ARCProbePrivateQuitDialogResult(true, "No dialog is showing") == "no-dialog")
    #expect(
      ARCProbePrivateQuitDialogResult(true, "unknown DevTools capability or command")
        == "devtools-error")
  }

  @Test func nativePrepareReleasesAnArmedHoldWhenSwiftWillNotOwnIt() {
    #expect(ARCProbeNativePrepareShouldReleaseHold(true, false, true, false, false))
    #expect(ARCProbeNativePrepareShouldReleaseHold(true, true, true, true, false))
    #expect(ARCProbeNativePrepareShouldReleaseHold(true, false, true, true, true))
    #expect(!ARCProbeNativePrepareShouldReleaseHold(true, false, true, true, false))
    #expect(!ARCProbeNativePrepareShouldReleaseHold(false, false, true, false, false))
    #expect(!ARCProbeNativePrepareShouldReleaseHold(true, true, false, false, true))
    #expect(!ARCProbeNativePrepareShouldReleaseHold(true, false, false, false, false))
  }

  @Test func nativeHoldAuditStaysHiddenWithoutASwiftOwner() {
    #expect(!ARCProbeNativeHoldAuditVisible(false, true))
    #expect(!ARCProbeNativeHoldAuditVisible(true, false))
    #expect(!ARCProbeNativeHoldAuditVisible(false, false))
    #expect(ARCProbeNativeHoldAuditVisible(true, true))
  }

  @Test func trustedClickAllowlistIncludesTheQuitActivationButton() {
    #expect(ARCProbeTrustedClickElementAllowed("blank"))
    #expect(ARCProbeTrustedClickElementAllowed("popup"))
    #expect(ARCProbeTrustedClickElementAllowed("plain"))
    #expect(ARCProbeTrustedClickElementAllowed("performance-input"))
    #expect(ARCProbeTrustedClickElementAllowed("arcusis-download-probe"))
    #expect(ARCProbeTrustedClickElementAllowed("window-client-download"))
    #expect(ARCProbeTrustedClickElementAllowed("external-consent-probe"))
    #expect(ARCProbeTrustedClickElementAllowed("arcusis-private-quit-activation"))
    #expect(!ARCProbeTrustedClickElementAllowed("parity-action"))
    #expect(!ARCProbeTrustedClickElementAllowed("quit"))
    #expect(!ARCProbeTrustedClickElementAllowed(""))
  }

  @Test func trustedScrollAllowlistIsLimitedToTheInfiniteScrollFixture() {
    #expect(ARCProbeTrustedScrollElementAllowed("feed"))
    #expect(!ARCProbeTrustedScrollElementAllowed("popup"))
    #expect(!ARCProbeTrustedScrollElementAllowed(""))
  }
}
