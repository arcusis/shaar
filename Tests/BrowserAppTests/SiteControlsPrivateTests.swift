// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class PrivateCookieFailureRuntime: ARCChromiumRuntime {
  var failsReads = false
  var failsWrites = false

  override func privateCookies(
    forTabID tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (NSNumber?, Error?) -> Void
  ) {
    if failsReads {
      completion(nil, NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."]))
    } else {
      completion(NSNumber(value: false), nil)
    }
  }

  override func setPrivateCookiesAllowed(
    _ allowed: Bool, tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    if failsWrites {
      completion(NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."]))
    } else {
      completion(nil)
    }
  }
}

@Suite @MainActor
struct SiteControlsPrivateTests {
  @Test func panelTitleIsVoiceOverHeading() {
    #expect(PrivateSiteControlsPanel.headingTraits.contains(.isHeader))
  }

  @Test func privateTargetRetainsWindowContextAndCanonicalOrigin() throws {
    let tabID = UUID().uuidString
    let windowID = UUID().uuidString
    let contextID = UUID().uuidString
    let model = try #require(
      PrivateSiteControlsModel(
        tabID: tabID, windowID: windowID, contextID: contextID,
        url: URL(string: "https://account.example:8443/settings?mode=private#cookies")!,
        runtime: ARCChromiumRuntime()))

    #expect(model.tabID == tabID)
    #expect(model.windowID == windowID)
    #expect(model.contextID == contextID)
    #expect(model.origin == "https://account.example:8443")
  }

  @Test func privateTargetRejectsURLsWithoutAWebOrigin() {
    let runtime = ARCChromiumRuntime()
    for url in [URL(string: "file:///tmp/profile.html")!, URL(string: "data:text/plain,private")!] {
      #expect(
        PrivateSiteControlsModel(
          tabID: UUID().uuidString, windowID: UUID().uuidString,
          contextID: UUID().uuidString, url: url, runtime: runtime) == nil)
    }
  }

  @Test func privateCookieFailuresUseLocalizedRecoveryMessages() async throws {
    let runtime = PrivateCookieFailureRuntime()
    let model = try #require(
      PrivateSiteControlsModel(
        tabID: UUID().uuidString, windowID: UUID().uuidString,
        contextID: UUID().uuidString, url: URL(string: "https://example.test")!, runtime: runtime))

    runtime.failsReads = true
    await model.load()
    #expect(model.failure == ShellL10n.string("Could not load private site cookie settings. Try again."))

    runtime.failsReads = false
    await model.load()
    runtime.failsWrites = true
    await model.setAllowed(true)
    #expect(model.failure == ShellL10n.string("Could not update private site cookie settings. Try again."))
  }
}
