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
    let expectedReason =
      pageText.localizedCaseInsensitiveContains("not private")
      || pageText.localizedCaseInsensitiveContains("ERR_CERT")
    let passed = isCertificateError(security) && expectedReason && !loadedFixture
    let address = href.isEmpty ? committedURL : href
    let unknown = security.isEmpty && pageText.isEmpty && href.isEmpty && committedURL.isEmpty
    let evidence =
      passed
      ? "Certificate error interstitial for the untrusted fixture."
      : "A chrome-error page is not a certificate failure unless the security level is certificateError and the interstitial names the bad certificate. security \(security); \(address)"
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : (unknown ? "probe" : "gap"), evidence: evidence
    )
  }

  static func httpsFirst(
    href: String, committedURL: String, pageText: String, outcome: String, security: String,
    loopbackPeer: String
  ) -> PlatformParityDecision {
    guard loopbackMapped(loopbackPeer) else {
      return PlatformParityDecision(
        passed: false, disposition: "probe",
        evidence:
          "trackertest.org did not connect to 127.0.0.1, so this row does not measure HTTPS-first.")
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
      evidence =
        "Plain http did not load. The browser upgraded the page or showed an HTTPS interstitial."
    } else if loadedPlain {
      evidence = "Plain http loaded on the mapped host. address \(address); security \(security)"
    } else {
      evidence =
        "A chrome-error page without an HTTPS interstitial is not HTTPS-first. address \(address); security \(security)"
    }
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : "gap", evidence: evidence)
  }

  /// A permission call that resolves without the matching prompt is not a pass.
  static func permissionPrompt(
    kind: String, kinds: [String], outcome: String
  ) -> PlatformParityDecision {
    let prompted = kinds.contains(kind)
    let evidence =
      prompted
      ? "The \(kind) permission prompt appeared."
      : "The \(kind) call did not show a \(kind) permission prompt. outcome \(outcome)"
    return PlatformParityDecision(
      passed: prompted, disposition: prompted ? "pass" : "gap", evidence: evidence)
  }

  /// beforeprint and afterprint are page events. A pass needs a print surface.
  static func printSurface(
    outcome: String, beforePrint: Bool, surfaces: [String]
  ) -> PlatformParityDecision {
    let surfaced = surfaces.contains { $0.localizedCaseInsensitiveContains("print") }
    let evidence =
      surfaced
      ? "A print surface appeared."
      : "beforeprint or afterprint without a print surface is not print UI. outcome \(outcome); beforeprint \(beforePrint)"
    return PlatformParityDecision(
      passed: surfaced, disposition: surfaced ? "pass" : "gap", evidence: evidence)
  }

  /// The product list can contain an extension this run never installed.
  static func extensions(listed: [String], installedMV3: Bool) -> PlatformParityDecision {
    let names = listed.isEmpty ? "product list empty" : listed.joined(separator: "; ")
    let passed = installedMV3 && !listed.isEmpty
    let evidence =
      passed
      ? "This run installed an MV3 extension and it is in the product list. \(names)"
      : "No MV3 extension was installed by this run. \(names)"
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : "gap", evidence: evidence)
  }

  /// An absent Safe Browsing pref is not evidence that the feature is on.
  static func safeBrowsing(
    preferenceFilePresent: Bool, enabled: String
  ) -> PlatformParityDecision {
    if !preferenceFilePresent {
      return PlatformParityDecision(
        passed: false, disposition: "probe",
        evidence: "No Chromium preferences file was written.")
    }
    if enabled == "true" {
      return PlatformParityDecision(
        passed: true, disposition: "pass", evidence: "safebrowsing.enabled is true.")
    }
    if enabled == "false" {
      return PlatformParityDecision(
        passed: false, disposition: "gap", evidence: "safebrowsing.enabled is false.")
    }
    return PlatformParityDecision(
      passed: false, disposition: "probe",
      evidence: "safebrowsing.enabled was not in the preferences file.")
  }

  /// An unread cross-site frame has an empty store, which is not partitioning.
  static func partition(
    writeOpened: Bool, readOpened: Bool, writeMode: String, writeStored: String,
    readMode: String, readStored: String, readCookie: String
  ) -> PlatformParityDecision {
    let reported = writeOpened && readOpened && writeMode == "write" && readMode == "read"
    if !reported {
      return PlatformParityDecision(
        passed: false, disposition: "probe",
        evidence:
          "The partition fixtures did not both open and report. write opened \(writeOpened) mode \(writeMode) stored \(writeStored); read opened \(readOpened) mode \(readMode) stored \(readStored)"
      )
    }
    let wrote = writeStored == "alpha"
    let isolated = readStored.isEmpty && !readCookie.contains("legacy=1")
    let passed = wrote && isolated
    let evidence =
      passed
      ? "The cross-site frame opened, the write stored alpha, and the read was empty."
      : "Partition read did not stay empty after the write. write stored \(writeStored); read stored \(readStored); cookie \(readCookie)"
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : "gap", evidence: evidence)
  }

  /// `activate` and `makeKey` are window events. A note may already say `event `.
  static func isActivationEvent(_ name: String) -> Bool {
    let body = name.hasPrefix("event ") ? String(name.dropFirst(6)) : name
    return body == "activate" || body == "makeKey" || body.hasPrefix("makeKey ")
  }

  /// A chooser is a modal, a visible window, a sheet, or a panel. The probe's own
  /// window and activation notes are not choosers.
  static func isChooserSurface(_ name: String, hostWindow: String = "") -> Bool {
    if isActivationEvent(name) { return false }
    if !hostWindow.isEmpty, name == hostWindow || name == "visible \(hostWindow)" {
      return false
    }
    let folded = name.lowercased()
    return folded.contains("modal") || folded.contains("visible") || folded.contains("sheet")
      || folded.contains("panel")
  }

  static func deviceChooser(
    outcome: String, sheet: String, surfaces: [String], hostWindow: String = ""
  ) -> PlatformParityDecision {
    let choosers = surfaces.filter { isChooserSurface($0, hostWindow: hostWindow) }
    let appeared = !sheet.isEmpty || !choosers.isEmpty
    let passed = outcome == "resolved" || appeared
    let evidence: String
    if passed && appeared {
      evidence = "A chooser surface appeared."
    } else if passed {
      evidence = "The chooser request resolved."
    } else if surfaces.contains(where: isActivationEvent) {
      evidence = "activate and makeKey are window events, not a chooser."
    } else {
      evidence = "No chooser surface appeared."
    }
    return PlatformParityDecision(
      passed: passed, disposition: passed ? "pass" : "gap", evidence: evidence)
  }
}
