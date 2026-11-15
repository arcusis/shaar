// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ShaarVerification

@Suite struct LocalExtensionInstallProbeEvidenceTests {
  @Test func contentScriptNeedsTheExpectedMarker() {
    #expect(LocalExtensionInstallProbeEvidence.hasContentScriptMarker(["marker": "local-mv3-v1"]))
    #expect(!LocalExtensionInstallProbeEvidence.hasContentScriptMarker(["marker": "other"]))
    #expect(!LocalExtensionInstallProbeEvidence.hasContentScriptMarker(["marker": true]))
    #expect(!LocalExtensionInstallProbeEvidence.hasContentScriptMarker(nil))
  }

  @Test func installConsentMustMatchProfileTabAndSource() throws {
    let profileID = UUID()
    let tabID = UUID()
    let sourceURL = URL(string: "http://127.0.0.1:8080/account")!
    let browserExtension = try #require(
      BrowserExtension(
        id: "abcdefghijklmnopabcdefghijklmnop",
        name: LocalExtensionInstallProbeEvidence.extensionName, version: "1.0"))
    let request = try #require(
      ExtensionInstallRequest(
        id: "request-1", profileID: profileID, tabID: tabID, sourceURL: sourceURL,
        browserExtension: browserExtension, kind: .install, permissions: []))
    #expect(
      LocalExtensionInstallProbeEvidence.consentMatches(
        request, profileID: profileID, tabID: tabID, sourceURL: sourceURL))
    #expect(
      !LocalExtensionInstallProbeEvidence.consentMatches(
        request, profileID: UUID(), tabID: tabID, sourceURL: sourceURL))
    #expect(
      !LocalExtensionInstallProbeEvidence.consentMatches(
        request, profileID: profileID, tabID: UUID(), sourceURL: sourceURL))
    #expect(
      !LocalExtensionInstallProbeEvidence.consentMatches(
        request, profileID: profileID, tabID: tabID,
        sourceURL: URL(string: "http://127.0.0.1:8080/other")!))
  }

  @Test func waitsForConsentBoundToTheSelectedSourceContext() throws {
    let profileID = UUID()
    let tabID = UUID()
    let sourceURL = URL(string: "http://127.0.0.1:8080/account")!
    let profile = BrowserProfile(id: profileID, name: "Probe")
    let tab = BrowserTab(id: tabID, url: sourceURL)
    let space = BrowserSpace(
      profileID: profileID, name: "Probe", symbol: "square", tint: .lavender,
      tabs: [tab], selectedTabID: tabID)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let browserExtension = try #require(
      BrowserExtension(
        id: "abcdefghijklmnopabcdefghijklmnop",
        name: LocalExtensionInstallProbeEvidence.extensionName, version: "1.0"))
    let stale = try #require(
      ExtensionInstallRequest(
        id: "stale", profileID: UUID(), tabID: tabID, sourceURL: sourceURL,
        browserExtension: browserExtension, kind: .install, permissions: []))
    let current = try #require(
      ExtensionInstallRequest(
        id: "current", profileID: profileID, tabID: tabID, sourceURL: sourceURL,
        browserExtension: browserExtension, kind: .install, permissions: []))

    #expect(
      LocalExtensionInstallProbeEvidence.boundConsent(
        in: [stale], profileID: profileID, tabID: tabID, sourceURL: sourceURL,
        session: session) == nil)
    #expect(
      LocalExtensionInstallProbeEvidence.boundConsent(
        in: [stale, current], profileID: profileID, tabID: tabID, sourceURL: sourceURL,
        session: session) == current)
  }
}
