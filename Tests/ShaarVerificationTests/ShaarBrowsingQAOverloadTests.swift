// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAOverloadTests {
  @Test func extraTabVerdictRequiresNewSelectedExtraTabToSettle() {
    let first = UUID()
    let extra = UUID()
    #expect(
      ShaarBrowsingQA.overloadExtraTabPassed(
        beforeCount: 50, afterCount: 51, beforeTabID: first, selectedTabID: extra,
        selectedURL: URL(string: "http://127.0.0.1:43100/light?n=extra")!, settled: true))
    #expect(
      !ShaarBrowsingQA.overloadExtraTabPassed(
        beforeCount: 50, afterCount: 50, beforeTabID: first, selectedTabID: first,
        selectedURL: URL(string: "http://127.0.0.1:43100/light?n=0")!, settled: true))
    #expect(
      !ShaarBrowsingQA.overloadExtraTabPassed(
        beforeCount: 50, afterCount: 51, beforeTabID: first, selectedTabID: extra,
        selectedURL: URL(string: "http://127.0.0.1:43100/light?n=extra")!, settled: false))
  }
}
