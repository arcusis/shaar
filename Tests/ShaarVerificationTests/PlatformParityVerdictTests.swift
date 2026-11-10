// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite
struct PlatformParityVerdictTests {
  @Test func chromeErrorWithoutCertificateErrorFails() {
    let decision = PlatformParityVerdicts.certificate(
      security: "", pageText: "This site can't be reached", outcome: "",
      href: "chrome-error://chromewebdata/", committedURL: "chrome-error://chromewebdata/")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func certificateErrorWithoutTheInterstitialTextFails() {
    let decision = PlatformParityVerdicts.certificate(
      security: "certificateError", pageText: "", outcome: "",
      href: "chrome-error://chromewebdata/", committedURL: "")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func untrustedCertificateInterstitialPasses() {
    let decision = PlatformParityVerdicts.certificate(
      security: "certificateError", pageText: "Your connection is not private",
      outcome: "", href: "chrome-error://chromewebdata/", committedURL: "")
    #expect(decision.passed)
    #expect(decision.disposition == "pass")
  }

  @Test func loadedFixtureIsNotACertificateBlock() {
    let decision = PlatformParityVerdicts.certificate(
      security: "certificateError", pageText: "bad cert page loaded",
      outcome: "loaded", href: "https://127.0.0.1/bad-cert", committedURL: "")
    #expect(!decision.passed)
  }

  @Test func emptyCertificateObservationStaysAProbe() {
    let decision = PlatformParityVerdicts.certificate(
      security: "", pageText: "", outcome: "", href: "", committedURL: "")
    #expect(!decision.passed)
    #expect(decision.disposition == "probe")
  }

  @Test func chromeErrorWithoutAnHttpsInterstitialFailsHttpsFirst() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "chrome-error://chromewebdata/", committedURL: "",
      pageText: "This site can't be reached", outcome: "", security: "",
      loopbackPeer: "127.0.0.1")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func certificateErrorAloneIsNotHttpsFirst() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "chrome-error://chromewebdata/", committedURL: "",
      pageText: "Your connection is not private", outcome: "", security: "certificateError",
      loopbackPeer: "127.0.0.1")
    #expect(!decision.passed)
  }

  @Test func httpsInterstitialPassesWhenLoopbackIsProven() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "chrome-error://chromewebdata/", committedURL: "",
      pageText: "This site does not support HTTPS", outcome: "", security: "",
      loopbackPeer: "127.0.0.1")
    #expect(decision.passed)
  }

  @Test func plainHttpOnTheMappedHostFailsHttpsFirst() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "http://trackertest.org:9/plain", committedURL: "", pageText: "plain http",
      outcome: "loaded", security: "insecure", loopbackPeer: "127.0.0.1")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
    #expect(decision.evidence.contains("Plain http loaded"))
  }

  @Test func httpsFirstWaitsUntilLoopbackIsProven() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "https://trackertest.org/plain", committedURL: "", pageText: "",
      outcome: "", security: "", loopbackPeer: "")
    #expect(!decision.passed)
    #expect(decision.disposition == "probe")
  }

  @Test func loopbackPeerIsTheLoopbackAddress() {
    #expect(PlatformParityVerdicts.loopbackMapped("127.0.0.1"))
    #expect(!PlatformParityVerdicts.loopbackMapped(""))
    #expect(!PlatformParityVerdicts.loopbackMapped("93.184.216.34"))
  }
}
