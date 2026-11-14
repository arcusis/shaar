// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct PrivateWindowHistoryPathsTests {
  @Test func extractsURLPathsAndIgnoresMalformedHistoryRows() {
    let rows: [[AnyHashable: Any]] = [
      ["u": "http://127.0.0.1:48000/account/normal?session=1"],
      ["u": "https://example.invalid/private/path#fragment"],
      ["u": "not a URL"],
      ["u": 42],
      ["title": "missing URL"],
    ]
    #expect(PrivateWindowProbe.historyPaths(rows) == ["/account/normal", "/private/path"])
    #expect(PrivateWindowProbe.historyPaths(nil).isEmpty)
    #expect(PrivateWindowProbe.historyPaths([]).isEmpty)
  }

  @Test func historyRowsRequireAnAbsoluteURLWithAHost() {
    let rows: [[AnyHashable: Any]] = [
      ["u": "relative/path"],
      ["u": "https:///missing-host/path"],
    ]
    #expect(PrivateWindowProbe.historyPaths(rows).isEmpty)
  }
}
