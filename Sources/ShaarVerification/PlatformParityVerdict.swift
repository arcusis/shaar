// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct PlatformParityDecision: Equatable {
  var passed: Bool
  var disposition: String
  var evidence: String
}

/// Pass and fail rules for the platform-parity probe. A chrome-error URL is not
/// a certificate failure or an HTTPS-first interstitial on its own.
enum PlatformParityVerdicts {
  static func isCertificateError(_ security: String) -> Bool {
    security == "certificateError"
  }

  static func loopbackMapped(_ peer: String) -> Bool {
    peer == "127.0.0.1"
  }

  static func certificate(
    security: String, pageText: String, outcome: String, href: String, committedURL: String
  ) -> PlatformParityDecision {
    let loadedFixture = pageText.contains("bad cert page loaded") || outcome == "loaded"
    let expectedReason = pageText.localizedCaseInsensitiveContains("not private")
      || pageText.localizedCaseInsensitiveContains("ERR_CERT")
    let passed = isCertificateError(security) && expectedReason && !loadedFixture
    let address = href.isEmpty ? committedURL : href
    let unknown = security.isEmpty && pageText.isEmpty && href.isEmpty && committedURL.isEmpty
    let evidence = passed
      ? "Certificate error interstitial for the untrusted fixture."
      : "A chrome-error page is not a certificate failure unless the security level is certificateError and the interstitial names the bad certificate. security \(security); \(address)"
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : (unknown ? "probe" : "gap"), evidence: evidence)
  }

  static func httpsFirst(
    href: String, committedURL: String, pageText: String, outcome: String, security: String,
    loopbackPeer: String
  ) -> PlatformParityDecision {
    guard loopbackMapped(loopbackPeer) else {
      return PlatformParityDecision(
        passed: false, disposition: "probe",
        evidence: "trackertest.org did not connect to 127.0.0.1, so this row does not measure HTTPS-first.")
    }
    let address = href.isEmpty ? committedURL : href
    let loadedPlain = outcome == "loaded" && address.hasPrefix("http:")
    let upgraded = address.hasPrefix("https:") && !address.contains("chrome-error")
    let namesHTTPS = pageText.localizedCaseInsensitiveContains("https")
    let onErrorPage = address.contains("chrome-error") || isCertificateError(security)
    let interstitial = namesHTTPS && onErrorPage && !address.hasPrefix("http:")
    let passed = !loadedPlain && (upgraded || interstitial)
    let evidence: String
    if passed {
      evidence = "Plain http did not load. The browser upgraded the page or showed an HTTPS interstitial."
    } else if loadedPlain {
      evidence = "Plain http loaded on the mapped host. address \(address); security \(security)"
    } else {
      evidence = "A chrome-error page without an HTTPS interstitial is not HTTPS-first. address \(address); security \(security)"
    }
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : "gap", evidence: evidence)
  }
}
