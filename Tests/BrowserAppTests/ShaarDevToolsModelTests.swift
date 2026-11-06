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
    #expect(shell.streamAvailable)
    #expect(shell.events == fixture)
    #expect(shell.consoleCount == 1 && shell.networkCount == 1)
    #expect(shell.repro.history.snapshot().console.count == 1)
    #expect(shell.repro.history.snapshot().network.count == 1)

    shell.close()
    #expect(!shell.isOpen && !inspector.isOpen)
    #expect(shell.repro.history.snapshot().console.isEmpty)
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

  @Test func productionTransportNeverEnablesFixtureEvents() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target)
    shell.open(inspector: inspector)
    for _ in 0..<10 { await Task.yield() }
    #expect(!shell.streamAvailable && shell.events.isEmpty)
    shell.close()
  }

  @Test func viewportTransportRunsOnlyWhileItsSectionIsSelected() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target)
    shell.open(inspector: inspector)
    #expect(!shell.viewports.isOpen)
    shell.section = .viewports
    #expect(shell.viewports.isOpen)
    shell.section = .console
    #expect(!shell.viewports.isOpen)
    shell.close()
  }

  @Test func losingStreamCapabilityClearsLiveEvents() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let fixture: [ShaarDevToolsEvent] = [
      .console(ShaarConsoleEvent(id: UUID(), level: .log, message: "Ready", source: nil))
    ]
    let shell = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: fixture, revokeAfterEvents: true))
    shell.open(inspector: inspector)
    for _ in 0..<20 { await Task.yield() }
    #expect(!shell.streamAvailable && shell.events.isEmpty)
    shell.close()
  }

  @Test func dockSizesRespectTheAvailablePane() {
    #expect(ShaarDevToolsSizing.bottom(100, available: 1_000) == 240)
    #expect(ShaarDevToolsSizing.bottom(900, available: 1_000) == 700)
    #expect(ShaarDevToolsSizing.right(100, available: 1_000) == 320)
    #expect(ShaarDevToolsSizing.right(900, available: 1_000) == 500)
  }

  @Test func reproHistoryEvictsOldEventsAndRejectsOtherTabs() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let other = SiteControlTarget(
      tabID: UUID(), profileID: target.profileID, url: target.url)
    let history = ShaarReproHistory()
    let now = Date(timeIntervalSince1970: 1_000)
    history.start(for: target)
    history.record(
      .console(ShaarConsoleEvent(id: UUID(), level: .log, message: "old", source: nil)),
      for: target, at: now.addingTimeInterval(-31))
    history.record(
      .console(ShaarConsoleEvent(id: UUID(), level: .log, message: "current", source: nil)),
      for: target, at: now)
    history.record(
      .network(
        ShaarNetworkEvent(
          id: UUID(), method: "GET", url: "https://other.example/", status: 200)),
      for: other, at: now)
    let snapshot = history.snapshot(at: now)
    #expect(snapshot.console.map(\.message) == ["current"])
    #expect(snapshot.network.isEmpty)
  }
}
