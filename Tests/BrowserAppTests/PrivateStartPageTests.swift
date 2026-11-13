// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite
struct PrivateStartPageTests {
  private let completeStatus: [AnyHashable: Any] = [
    "offTheRecord": true,
    "globalCookies": "block",
    "trackerProtectionEnabled": true,
    "trackerDomainCount": 1,
    "trackerRulesRevision": "rules-v1",
    "httpsOnly": true,
    "referrersEnabled": false,
    "webRTCIPHandlingPolicy": "disable_non_proxied_udp",
    "webRTCPolicyExceptionCount": 0,
    "localIPExceptionCount": 0,
    "extensionsDisabled": true,
  ]

  @Test func protectionStatusRequiresEveryExplicitPrivateGuarantee() {
    #expect(PrivateProtectionStatus(completeStatus).allEnabled)

    for key in completeStatus.keys {
      var partial = completeStatus
      partial[key] = nil
      #expect(!PrivateProtectionStatus(partial).allEnabled, "Missing \(key) must fail closed")
    }

    var ordinaryProfile = completeStatus
    ordinaryProfile["offTheRecord"] = false
    #expect(!PrivateProtectionStatus(ordinaryProfile).allEnabled)
  }

  @Test func trackerAndWebRTCClaimsRequireTheirSupportingEvidence() {
    var status = completeStatus
    status["trackerDomainCount"] = 0
    #expect(!PrivateProtectionStatus(status).trackers)

    status = completeStatus
    status["trackerRulesRevision"] = ""
    #expect(!PrivateProtectionStatus(status).trackers)

    status = completeStatus
    status["localIPExceptionCount"] = 1
    #expect(!PrivateProtectionStatus(status).webRTC)
  }
}
