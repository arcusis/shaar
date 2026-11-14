// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct AgentBridgeViewTests {
  @Test func presentationDistinguishesDisabledAndUnconfirmedRevocation() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    var disableReply: AgentBridgeModel.Reply?
    let model = AgentBridgeModel(target: target) { operation, _, reply in
      switch operation {
      case .enable:
        reply([
          "schemaVersion": 1, "enabled": true, "port": 9222,
          "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
          "connectionCount": 1, "token": String(repeating: "a", count: 43),
        ], nil)
      case .disable:
        disableReply = reply
      case .status:
        break
      }
    }

    let disabled = AgentBridgePresentation(model: model)
    #expect(disabled.title == "Agent bridge is off for this tab")
    #expect(disabled.symbol == "network")
    #expect(disabled.tint == .secondary)

    model.enable()
    model.update(
      target: SiteControlTarget(
        tabID: target.tabID, profileID: target.profileID,
        url: URL(string: "https://other.test/")!), committed: true)

    let revoking = AgentBridgePresentation(model: model)
    #expect(model.revocationUnconfirmed)
    #expect(revoking.title == "Agent disconnect not confirmed")
    #expect(revoking.symbol == "exclamationmark.triangle.fill")
    #expect(revoking.tint == .orange)
    disableReply?(nil, AgentBridgeFailure.invalidReply)
  }
}
