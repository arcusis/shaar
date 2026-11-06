// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Interprets observations collected by the engine probe; missing evidence never passes.
enum PrivatePrivacyEvidence {
  static func permissionPresentation(_ observations: [String: Any]) -> [String: Bool] {
    [
      "permissionRendererVisibilityScoped":
        observations["before"] as? String == "hidden"
        && observations["during"] as? String == "visible"
        && observations["completion"] as? String == "visible"
        && observations["after"] as? String == "hidden",
      "permissionNativeWindowsHiddenBeforeAndAfter":
        observations["nativeWindowsHiddenBefore"] as? Bool == true
        && observations["nativeWindowsHiddenAfter"] as? Bool == true,
    ]
  }

  static func engineStatus(_ status: [AnyHashable: Any]) -> [String: Bool] {
    [
      "privateEngineProfileIsOffTheRecord": status["offTheRecord"] as? Bool == true,
      "privateEngineGlobalCookiesBlocked": status["globalCookies"] as? String == "block",
      "privateEngineHTTPSOnlyEnabled": status["httpsOnly"] as? Bool == true,
      "privateEngineReferrersDisabled": status["referrersEnabled"] as? Bool == false,
      "privateEngineWebRTCPublicIPOnly":
        status["webRTCIPHandlingPolicy"] as? String == "disable_non_proxied_udp"
        && status["webRTCPolicyExceptionCount"] as? Int == 0
        && status["localIPExceptionCount"] as? Int == 0,
      "privateEngineExtensionsDisabled": status["extensionsDisabled"] as? Bool == true,
      "privateEngineTrackerRulesLoaded":
        status["trackerProtectionEnabled"] as? Bool == true
        && (status["trackerDomainCount"] as? Int ?? 0) > 0
        && !(status["trackerRulesRevision"] as? String ?? "").isEmpty,
    ]
  }

  static func preferences(_ observations: [AnyHashable: Any]) -> [String: Bool] {
    let keys = [
      "credentials_enable_service", "autofill.profile_enabled", "autofill.credit_card_enabled",
    ]
    return [
      "privateAutofillAndPasswordSavingOff": keys.allSatisfy {
        (observations[$0] as? [String: Any])?["private"] as? Bool == false
      },
      "normalAutofillPreferencesUnchanged": keys.allSatisfy {
        (observations[$0] as? [String: Any])?["normal"] as? Bool == true
      },
      "wildcardCookieDefaultUnavailable":
        (observations["wildcardCookieSetting"] as? [String: Any])?["error"] as? String
        == "origin must be an http(s) origin",
    ]
  }

  static func storage(
    _ observations: [String: Any], allowed: Bool, includesIndexedDB: Bool
  ) -> Bool {
    let keys = ["cookie", "local", "session"] + (includesIndexedDB ? ["indexedDB"] : [])
    return keys.allSatisfy { observations[$0] as? Bool == allowed }
  }

  static func permissions(_ observations: [String: Any]) -> [String: Bool] {
    [
      "privatePermissionsDenied": ["camera", "microphone", "geolocation", "notifications"]
        .allSatisfy { observations[$0] as? String == "denied" },
      "privatePermissionRequestsRejected":
        observations["cameraRequest"] as? String == "NotAllowedError"
        && observations["microphoneRequest"] as? String == "NotAllowedError"
        && observations["locationRequest"] as? Int == 1
        && observations["notificationRequest"] as? String == "denied",
    ]
  }
}
