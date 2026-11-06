// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarDevToolsModelTests {
  @Test func fixtureStreamIsScopedAndInspectorOwnershipIsRestored() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/one")!)
    let fixture: [ShaarDevToolsEvent] = [
      .console(ShaarConsoleEvent(id: UUID(), level: .warning, message: "Slow render", source: nil)),
      .network(ShaarNetworkEvent(id: UUID(), method: "GET", url: "/api/items", status: 200)),
    ]
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(
      target: target, transport: ShaarDevToolsFixtureTransport(fixture: fixture))
    shell.open(inspector: inspector)
    for _ in 0..<20 where shell.events.count < 2 { await Task.yield() }
    #expect(shell.isOpen && inspector.isOpen)
    #expect(shell.events == fixture)
    #expect(shell.consoleCount == 1 && shell.networkCount == 1)

    shell.close()
    #expect(!shell.isOpen && !inspector.isOpen)
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/two")!)
    shell.updateTarget(next)
    #expect(shell.target == next && shell.events.isEmpty)
  }

  @Test func anAlreadyOpenInspectorSurvivesShellClose() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    let shell = ShaarDevToolsModel(target: target)
    shell.open(inspector: inspector)
    shell.close()
    #expect(inspector.isOpen)
    inspector.close()
  }

  @Test func dockSizesRespectTheAvailablePane() {
    #expect(ShaarDevToolsSizing.bottom(100, available: 1_000) == 240)
    #expect(ShaarDevToolsSizing.bottom(900, available: 1_000) == 700)
    #expect(ShaarDevToolsSizing.right(100, available: 1_000) == 320)
    #expect(ShaarDevToolsSizing.right(900, available: 1_000) == 500)
  }
}
