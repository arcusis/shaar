// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

private struct ShaarScaleFixtureTransport: ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      for index in 0..<50_000 {
        continuation.yield(
          .event(
            .console(
              .init(
                id: UUID(), level: .log, message: "message \(index)", source: nil))))
        continuation.yield(
          .event(
            .network(
              .init(
                id: UUID(), method: "GET", url: "https://example.com/item/\(index)",
                status: 200, time: Double(index)))))
      }
      continuation.finish()
    }
  }
}

@Suite @MainActor struct ShaarDevToolsModelTests {
  @Test func fixtureStreamIngestsFiftyThousandEntriesPerPanel() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let shell = ShaarDevToolsModel(
      target: target, transport: ShaarScaleFixtureTransport())
    let inspector = InspectorModel(target: target, engine: nil)
    let start = ContinuousClock.now
    shell.open(inspector: inspector)
    for _ in 0..<1_000 where shell.events.count < 100_000 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let elapsed = start.duration(to: .now)
    print("DevTools 100,000-event fixture stream: \(elapsed)")
    #expect(shell.consoleCount == 50_000)
    #expect(shell.networkCount == 50_000)
    #expect(shell.events.count == 100_000)
    #expect(elapsed < .seconds(10))
    shell.close()
  }

  @Test func longSessionRetainsFiftyThousandEntriesPerPanel() {
    var buffer = ShaarDevToolsEventBuffer()
    for index in 0..<51_000 {
      buffer.append(
        .console(
          .init(
            id: UUID(), level: .log, message: "message \(index)", source: nil)))
      buffer.append(
        .network(
          .init(
            id: UUID(), method: "GET", url: "/item/\(index)", status: 200)))
    }
    #expect(buffer.consoleCount == 50_000)
    #expect(buffer.networkCount == 50_000)
    #expect(buffer.droppedConsoleCount == 1_000)
    #expect(buffer.droppedNetworkCount == 1_000)
    #expect(buffer.events.count == 100_000)
    if case .console(let first) = buffer.events[0] {
      #expect(first.message == "message 1000")
    } else {
      Issue.record("The oldest retained event should be a console event")
    }
  }

  @Test func webKitComparisonIsScopedToNormalTabsAndSelectedSection() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let privateShell = ShaarDevToolsModel(target: target)
    #expect(!privateShell.sections.contains(.comparison))
    privateShell.section = .comparison
    #expect(privateShell.section == .elements)

    let inspector = InspectorModel(target: target, engine: nil)
    let normalShell = ShaarDevToolsModel(target: target, allowsWebKitComparison: true)
    #expect(normalShell.sections.contains(.comparison))
    normalShell.open(inspector: inspector)
    #expect(!normalShell.comparison.isOpen)
    normalShell.section = .comparison
    #expect(normalShell.comparison.isOpen)
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/next")!)
    normalShell.updateTarget(next)
    #expect(normalShell.comparison.target == next && normalShell.comparison.isOpen)
    normalShell.section = .console
    #expect(!normalShell.comparison.isOpen)
    normalShell.close()
  }

  @Test func networkLimitCountsRequestsAcrossMultiplePhases() {
    var buffer = ShaarDevToolsEventBuffer()
    for index in 0..<51_000 {
      let id = "request-\(index)"
      for phase in [
        ShaarNetworkEvent.Phase.request, .response, .data, .finished,
      ] {
        buffer.append(
          .network(
            .init(
              id: UUID(), method: "GET", url: "https://example.com/\(index)",
              status: 200, requestID: id, phase: phase)))
      }
    }
    #expect(buffer.networkCount == 50_000)
    #expect(buffer.droppedNetworkCount == 1_000)
    #expect(buffer.events.count == 200_000)
    if case .network(let first) = buffer.events[0] {
      #expect(first.requestID == "request-1000")
    } else {
      Issue.record("The oldest retained event should begin the next request")
    }
  }

  @Test func oversizedHistoryEvictsOlderEntriesWithinByteBudget() {
    var buffer = ShaarDevToolsEventBuffer()
    let largeMessage = String(repeating: "x", count: 100_000)
    for _ in 0..<1_000 {
      buffer.append(
        .console(
          .init(
            id: UUID(), level: .log, message: largeMessage, source: nil)))
    }
    #expect(buffer.retainedBytes <= 64 * 1_048_576)
    #expect(buffer.droppedConsoleCount > 0)
  }

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
    for _ in 0..<30 where inspector.isOpen { await Task.yield() }
    #expect(!shell.isOpen && !inspector.isOpen)
    #expect(shell.repro.history.snapshot().console.isEmpty)
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/two")!)
    shell.updateTarget(next)
    #expect(shell.target == next && shell.events.isEmpty)
  }

  @Test func sameTabNavigationKeepsThePanelLease() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/one")!)
    let transport = HeldDevToolsTransport()
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, transport: transport)
    shell.open(inspector: inspector)
    for _ in 0..<20 where !shell.streamAvailable { await Task.yield() }
    transport.emit(
      .console(ShaarConsoleEvent(id: UUID(), level: .log, message: "qa-log", source: nil)))
    transport.emit(
      .network(ShaarNetworkEvent(id: UUID(), method: "GET", url: "/api/items", status: 200)))
    for _ in 0..<20 where shell.consoleCount < 1 || shell.networkCount < 1 { await Task.yield() }
    #expect(shell.consoleCount == 1 && shell.networkCount == 1)
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/two")!)
    shell.updateTarget(next, committed: true)
    #expect(shell.events.isEmpty)
    #expect(shell.streamAvailable)
    #expect(transport.openings == 1)
    transport.emit(
      .console(ShaarConsoleEvent(id: UUID(), level: .error, message: "qa-error", source: nil)))
    transport.emit(
      .network(ShaarNetworkEvent(id: UUID(), method: "GET", url: "/api/xhr", status: 200)))
    for _ in 0..<20 where shell.consoleCount < 1 || shell.networkCount < 1 { await Task.yield() }
    #expect(shell.streamAvailable)
    #expect(shell.console.rows(from: shell.consoleEvents).contains {
      $0.event.message == "qa-error"
    })
    #expect(shell.network.requests(from: shell.events).contains { $0.url == "/api/xhr" })
    shell.close()
  }

  @Test func preserveLogKeepsConsoleAcrossNavigationAndClearDropsOnlyConsole() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/one")!)
    let warning = ShaarConsoleEvent(
      id: UUID(), level: .warning, message: "Slow render", source: nil)
    let network = ShaarNetworkEvent(id: UUID(), method: "GET", url: "/api/items", status: 200)
    let transport = OneShotDevToolsTransport(fixture: [.console(warning), .network(network)])
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, transport: transport)
    shell.open(inspector: inspector)
    for _ in 0..<20 where shell.consoleCount < 1 || shell.networkCount < 1 { await Task.yield() }
    #expect(shell.consoleCount == 1 && shell.networkCount == 1)
    shell.console.preserveLog = true
    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/two")!)
    shell.updateTarget(next, committed: true)
    #expect(shell.events.isEmpty)
    #expect(shell.console.rows(from: shell.consoleEvents).map(\.event.message) == ["Slow render"])
    shell.console.preserveLog = false
    shell.console.clearEntries()
    #expect(shell.console.rows(from: shell.consoleEvents).isEmpty)
    #expect(shell.console.history.isEmpty)
    var buffer = ShaarDevToolsEventBuffer()
    buffer.append(.console(warning))
    buffer.append(.network(network))
    let before = buffer.retainedBytes
    buffer.removeConsole()
    #expect(buffer.consoleCount == 0)
    #expect(buffer.networkCount == 1)
    #expect(buffer.droppedConsoleCount == 0)
    #expect(buffer.retainedBytes < before)
    #expect(buffer.retainedBytes >= 0)
    shell.close()
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
    #expect(ShaarDevToolsSizing.side(100, available: 1_000) == 320)
    #expect(ShaarDevToolsSizing.side(900, available: 1_000) == 500)
    #expect(ShaarDevToolsSizing.side(420, available: 620) == 310)
  }

  @Test func dockChoiceAndIndependentSizesSurviveReopening() {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsLayoutTests.\(UUID())")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    #expect(shell.dock == .right)
    shell.open(inspector: inspector)
    shell.section = .network
    shell.rightWidth = 470
    shell.leftWidth = 390
    shell.bottomHeight = 310
    shell.dock = .floating
    #expect(shell.isOpen && shell.section == .network)
    shell.dock = .left
    #expect(shell.isOpen && shell.section == .network)
    shell.close()
    let reopened = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    #expect(reopened.dock == .left)
    #expect(reopened.rightWidth == 470)
    #expect(reopened.leftWidth == 390)
    #expect(reopened.bottomHeight == 310)
  }

  @Test func dockingBackFromAnUnorderedWindowKeepsTheTabPanelOpen() {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let defaults = UserDefaults(suiteName: "ShaarDevToolsWindowTests.\(UUID())")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .network
    shell.dock = .floating
    shell.floatingWindow = ShaarDevToolsFloatingWindow(
      model: shell, inspector: inspector, openChromium: {})
    shell.dock = .right
    #expect(shell.floatingWindow == nil)
    #expect(shell.isOpen && shell.section == .network)
    #expect(NSApp.keyWindow === previous)
    shell.close()
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

  @Test func splitDragGrowsThePanelTowardThePage() {
    let right = ShaarDevToolsSplitDrag.proposed(
      start: 420, translation: ShaarDevToolsSplitDrag.translation(vertical: false, delta: -80),
      edge: .right, available: 1680)
    #expect(right == 500)
    let left = ShaarDevToolsSplitDrag.proposed(
      start: 420, translation: ShaarDevToolsSplitDrag.translation(vertical: false, delta: 40),
      edge: .left, available: 1680)
    #expect(left == 460)
    let raised = ShaarDevToolsSplitDrag.translation(vertical: true, delta: 30)
    #expect(raised == -30)
    let bottom = ShaarDevToolsSplitDrag.proposed(
      start: 400, translation: raised, edge: .bottom, available: 1040)
    #expect(bottom == 430)
  }
}

@MainActor private final class HeldDevToolsTransport: ShaarDevToolsEventTransport {
  private var continuation: AsyncStream<ShaarDevToolsTransportMessage>.Continuation?
  private(set) var openings = 0

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    openings += 1
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.yield(.streamAvailable)
    }
  }

  func emit(_ event: ShaarDevToolsEvent) {
    continuation?.yield(.event(event))
  }
}

@MainActor private final class OneShotDevToolsTransport: ShaarDevToolsEventTransport {
  let fixture: [ShaarDevToolsEvent]
  private var delivered = false

  init(fixture: [ShaarDevToolsEvent]) { self.fixture = fixture }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    let events = delivered ? [ShaarDevToolsEvent]() : fixture
    delivered = true
    return AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      for event in events { continuation.yield(.event(event)) }
      continuation.finish()
    }
  }
}
