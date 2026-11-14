// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAHistoryTests {
  @Test func reloadDuringNavigationPreservesThePriorHistoryEntry() {
    #expect(ShaarBrowsingQA.reloadHistoryPreserved(backPath: "/nav/1", forwardPath: "/slow-reload"))
    #expect(!ShaarBrowsingQA.reloadHistoryPreserved(backPath: "/nav/0", forwardPath: "/slow-reload"))
    #expect(!ShaarBrowsingQA.reloadHistoryPreserved(backPath: nil, forwardPath: "/slow-reload"))
    #expect(!ShaarBrowsingQA.reloadHistoryPreserved(backPath: "/nav/1", forwardPath: "/nav/2"))
    #expect(!ShaarBrowsingQA.reloadHistoryPreserved(backPath: "/nav/1", forwardPath: nil))
  }
}
