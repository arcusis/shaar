// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct ReloadWindowProbeEvidenceTests {
  @Test func crossSiteEvidenceRequiresTheTwoAuthoredHttpLoopbackHosts() {
    let source = URL(string: "http://127.0.0.1:43123/cross-site-a")!
    #expect(
      ReloadWindowProbeEvidence.isCrossSiteLoopbackNavigation(
        source: source, destination: "http://localhost:43210/cross-site-b"))
    for (origin, destination) in [
      ("https://127.0.0.1:43123/cross-site-a", "http://localhost:43210/cross-site-b"),
      ("http://example.test/cross-site-a", "http://localhost:43210/cross-site-b"),
      ("http://127.0.0.1:43123/cross-site-a", "https://localhost:43210/cross-site-b"),
      ("http://127.0.0.1:43123/cross-site-a", "http://127.0.0.1:43210/cross-site-b"),
      ("http://127.0.0.1:43123/cross-site-a", "not a URL"),
    ] {
      #expect(
        !ReloadWindowProbeEvidence.isCrossSiteLoopbackNavigation(
          source: URL(string: origin)!, destination: destination))
    }
    #expect(!ReloadWindowProbeEvidence.isCrossSiteLoopbackNavigation(source: source, destination: nil))
  }
}
