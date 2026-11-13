// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct SiteControlsPageReadinessTests {
  @Test func fixturePageRequiresDocumentInstanceForReloadEvidence() {
    #expect(SiteControlsPageReadiness.isReady(["fixture": "v1", "instance": "doc-1"]))
    #expect(!SiteControlsPageReadiness.isReady(["fixture": "v2", "instance": "doc-1"]))
    #expect(!SiteControlsPageReadiness.isReady(["fixture": "v1"]))
    #expect(!SiteControlsPageReadiness.isReady(["fixture": "v1", "instance": ""]))
    #expect(!SiteControlsPageReadiness.isReady(["instance": "doc-1"]))
  }
}
