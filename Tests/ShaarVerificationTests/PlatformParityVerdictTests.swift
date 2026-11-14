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

  @Test func certificateErrorDiagnosticsAcceptErrCertCodesCaseInsensitively() {
    for diagnostic in ["ERR_CERT_AUTHORITY_INVALID", "err_cert_common_name_invalid"] {
      let decision = PlatformParityVerdicts.certificate(
        security: "certificateError", pageText: diagnostic, outcome: "",
        href: "chrome-error://chromewebdata/", committedURL: "")
      #expect(decision.passed)
      #expect(decision.disposition == "pass")
    }
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
      pageText: "You are seeing this warning because this site does not support HTTPS.",
      outcome: "", security: "", loopbackPeer: "127.0.0.1")
    #expect(decision.passed)
  }

  @Test func theSecureConnectionHeadingPassesHttpsFirst() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "chrome-error://chromewebdata/", committedURL: "",
      pageText: "This site doesn\u{2019}t support a secure connection",
      outcome: "", security: "", loopbackPeer: "127.0.0.1")
    #expect(decision.passed)
  }

  @Test func anHttpsSubstringIsNotTheHttpsOnlyInterstitial() {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: "chrome-error://chromewebdata/", committedURL: "",
      pageText: "See https://example.com for help", outcome: "", security: "",
      loopbackPeer: "127.0.0.1")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
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

  @Test func resolvedClipboardWithoutAPromptFails() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "clipboard", kinds: [], outcome: "resolved")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func resolvedMidiWithoutAPromptFails() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "midi", kinds: [], outcome: "resolved")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func resolvedStorageAccessWithoutAPromptFails() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "storageAccess", kinds: [], outcome: "resolved")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func grantedNotificationWithoutAPromptFails() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "notifications", kinds: [], outcome: "resolved")
    #expect(!decision.passed)
  }

  @Test func resolvedLocationWithoutAPromptFails() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "location", kinds: [], outcome: "resolved")
    #expect(!decision.passed)
  }

  @Test func observedPermissionPromptPasses() {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: "midi", kinds: ["midi"], outcome: "resolved")
    #expect(decision.passed)
    #expect(decision.disposition == "pass")
  }

  @Test func beforePrintWithoutAPrintSurfaceFails() {
    let decision = PlatformParityVerdicts.printSurface(
      outcome: "called", beforePrint: true, surfaces: ["BrowserWindow"])
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func afterPrintWithoutAPrintSurfaceFails() {
    let decision = PlatformParityVerdicts.printSurface(
      outcome: "afterprint", beforePrint: true, surfaces: [])
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func printWithNoEventStaysAProbe() {
    let decision = PlatformParityVerdicts.printSurface(
      outcome: "", beforePrint: false, surfaces: ["BrowserWindow"])
    #expect(!decision.passed)
    #expect(decision.disposition == "probe")
  }

  @Test func printSurfacePasses() {
    let decision = PlatformParityVerdicts.printSurface(
      outcome: "called", beforePrint: true, surfaces: ["modal NSPrintPanel"])
    #expect(decision.passed)
  }

  @Test func listedExtensionWithoutAnInstallFails() {
    let decision = PlatformParityVerdicts.extensions(
      listed: ["Helper 1.0 enabled=true"], installedMV3: false)
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func emptyExtensionListWithoutAnInstallStaysAProbe() {
    let decision = PlatformParityVerdicts.extensions(listed: [], installedMV3: false)
    #expect(!decision.passed)
    #expect(decision.disposition == "probe")
  }

  @Test func installedMV3ExtensionPassesWhenItIsListed() {
    let decision = PlatformParityVerdicts.extensions(
      listed: ["Parity 1.0 enabled=true"], installedMV3: true)
    #expect(decision.passed)
  }

  @Test func installFlagWithAnEmptyListFails() {
    let decision = PlatformParityVerdicts.extensions(listed: [], installedMV3: true)
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func missingSafeBrowsingPrefIsAProbe() {
    let absentFile = PlatformParityVerdicts.safeBrowsing(
      preferenceFilePresent: false, enabled: "")
    #expect(!absentFile.passed)
    #expect(absentFile.disposition == "probe")
    let absentKey = PlatformParityVerdicts.safeBrowsing(
      preferenceFilePresent: true, enabled: "")
    #expect(!absentKey.passed)
    #expect(absentKey.disposition == "probe")
  }

  @Test func safeBrowsingEnabledPassesAndDisabledFails() {
    let enabled = PlatformParityVerdicts.safeBrowsing(
      preferenceFilePresent: true, enabled: "true")
    #expect(enabled.passed)
    let disabled = PlatformParityVerdicts.safeBrowsing(
      preferenceFilePresent: true, enabled: "false")
    #expect(!disabled.passed)
    #expect(disabled.disposition == "gap")
  }

  @Test func unreadPartitionFrameDoesNotPass() {
    let decision = PlatformParityVerdicts.partition(
      writeOpened: true, readOpened: false, writeMode: "write", writeStored: "alpha",
      readMode: "", readStored: "", readCookie: "")
    #expect(!decision.passed)
    #expect(decision.disposition == "probe")
  }

  @Test func partitionPassesWhenTheReadFrameOpenedAndTheWriteLanded() {
    let decision = PlatformParityVerdicts.partition(
      writeOpened: true, readOpened: true, writeMode: "write", writeStored: "alpha",
      readMode: "read", readStored: "", readCookie: "part=1")
    #expect(decision.passed)
    #expect(decision.disposition == "pass")
  }

  @Test func partitionFailsWhenTheReadStillSeesTheWrite() {
    let decision = PlatformParityVerdicts.partition(
      writeOpened: true, readOpened: true, writeMode: "write", writeStored: "alpha",
      readMode: "read", readStored: "alpha", readCookie: "legacy=1")
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
  }

  @Test func activateAndMakeKeyAreNotAChooser() {
    let decision = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "", surfaces: ["activate", "makeKey BrowserWindow"])
    #expect(!decision.passed)
    #expect(decision.disposition == "gap")
    let recorded = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "", surfaces: ["event activate", "event makeKey BrowserWindow"])
    #expect(!recorded.passed)
  }

  @Test func aModalPanelStillCountsAsAChooser() {
    let decision = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "", surfaces: ["modal NSOpenPanel", "event activate"])
    #expect(decision.passed)
    #expect(decision.disposition == "pass")
  }

  @Test func theProbeWindowIsNotAChooser() {
    let decision = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "", surfaces: ["visible BrowserWindow", "BrowserWindow"],
      hostWindow: "BrowserWindow")
    #expect(!decision.passed)
  }

  @Test func browserWindowClassesAreNotAChooser() {
    for name in PlatformParityVerdicts.browserWindowClasses {
      let decision = PlatformParityVerdicts.deviceChooser(
        outcome: "", sheet: "", surfaces: ["visible \(name)", "modal \(name)"])
      #expect(!decision.passed)
      #expect(decision.disposition == "gap")
    }
    let owned = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "", surfaces: ["visible AnotherBrowserWindow"],
      browserWindows: ["AnotherBrowserWindow"])
    #expect(!owned.passed)
    let chooser = PlatformParityVerdicts.deviceChooser(
      outcome: "", sheet: "",
      surfaces: ["visible NSOpenPanel", "modal NativeWidgetMacFramelessNSWindow"])
    #expect(chooser.passed)
    #expect(chooser.disposition == "pass")
  }

  @Test func aResolvedChooserPassesWithoutASurface() {
    let decision = PlatformParityVerdicts.deviceChooser(
      outcome: "resolved", sheet: "", surfaces: ["activate", "makeKey BrowserWindow"])
    #expect(decision.passed)
  }
}
