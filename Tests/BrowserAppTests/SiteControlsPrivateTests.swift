// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

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
}
