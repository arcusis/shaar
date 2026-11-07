// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct DevToolsNetworkRulePageFetchTests {
  @Test func expressionFetchesTheExactURLWithoutCache() {
    let expression = DevToolsNetworkRulePageFetch.expression(
      for: "http://127.0.0.1:9/inspector-echo-header?shaar-rule=tab")
    #expect(expression.contains("\"http://127.0.0.1:9/inspector-echo-header?shaar-rule=tab\""))
    #expect(expression.contains("cache:'no-store'"))
    #expect(expression.contains("X-Shaar-Mock"))
  }

  @Test func receiptKeepsStatusHeaderAndBody() throws {
    let receipt = try DevToolsNetworkRulePageFetch.receipt(from: "218\nfrom-file\nshaar-file-body")
    #expect(receipt.status == 218)
    #expect(receipt.header == "from-file")
    #expect(receipt.body == "shaar-file-body")
  }

  @Test func receiptRejectsAShortPageResult() {
    #expect(throws: DevToolsNetworkRulePageFetch.FetchError.self) {
      try DevToolsNetworkRulePageFetch.receipt(from: "200 ok")
    }
  }
}
