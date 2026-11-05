// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct UpgradeProbeTests {
  @Test func requiresEveryMigratedDataCheck() {
    let complete: [String: Bool] = [
      "tabsAndProfiles": true,
      "cookie_alpha": true,
      "cookie_beta": true,
      "bookmarks_alpha": true,
      "bookmarks_beta": true,
      "headless": true,
    ]
    #expect(UpgradeProbe.reportPassed(checks: complete, error: nil))
    for name in complete.keys {
      var missing = complete
      missing.removeValue(forKey: name)
      #expect(!UpgradeProbe.reportPassed(checks: missing, error: nil))
    }
    #expect(!UpgradeProbe.reportPassed(checks: complete, error: "failed"))
  }

  @Test func findsChromiumBookmarkTitlesInCompactTree() {
    let tree: [String: Any] = [
      "bar": ["children": [["t": "Alpha console", "u": "http://127.0.0.1/account"]]]
    ]
    #expect(UpgradeProbe.containsBookmarkTitle("Alpha console", in: tree))
    #expect(!UpgradeProbe.containsBookmarkTitle("Beta console", in: tree))
  }
}
