// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarDevToolsSection: String, CaseIterable {
  case elements = "Elements"
  case console = "Console"
  case network = "Network"
}

enum ShaarDevToolsDock: String, CaseIterable {
  case bottom = "Dock to bottom"
  case right = "Dock to right"
}

struct ShaarConsoleEvent: Equatable, Sendable {
  enum Level: String, Sendable { case log, info, warning, error }
  let id: UUID
  let level: Level
  let message: String
  let source: String?
}

struct ShaarNetworkEvent: Equatable, Sendable {
  let id: UUID
  let method: String
  let url: String
  let status: Int?
}

enum ShaarDevToolsEvent: Equatable, Sendable {
  case console(ShaarConsoleEvent)
  case network(ShaarNetworkEvent)
}

@MainActor
protocol ShaarDevToolsEventTransport {
  func events(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsEvent>
}

/// A quiet production transport until the engine stream is connected in #1123.
struct ShaarDevToolsPendingTransport: ShaarDevToolsEventTransport {
  func events(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsEvent> {
    AsyncStream { _ in }
  }
}

struct ShaarDevToolsFixtureTransport: ShaarDevToolsEventTransport {
  let fixture: [ShaarDevToolsEvent]

  func events(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsEvent> {
    AsyncStream { continuation in
      for event in fixture { continuation.yield(event) }
      continuation.finish()
    }
  }
}

@MainActor @Observable
final class ShaarDevToolsModel {
  private(set) var target: SiteControlTarget
  private(set) var isOpen = false
  var section: ShaarDevToolsSection = .elements
  var dock: ShaarDevToolsDock = .bottom
  var bottomHeight: CGFloat = 380
  var rightWidth: CGFloat = 420
  private(set) var events: [ShaarDevToolsEvent] = []
  @ObservationIgnored private let transport: any ShaarDevToolsEventTransport
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var streamGeneration = 0
  @ObservationIgnored private var ownedInspector: InspectorModel?

  init(
    target: SiteControlTarget,
    transport: any ShaarDevToolsEventTransport = ShaarDevToolsPendingTransport()
  ) {
    self.target = target
    self.transport = transport
  }

  func open(inspector: InspectorModel) {
    guard !isOpen else { return }
    if !inspector.isOpen {
      inspector.open()
      ownedInspector = inspector
    }
    isOpen = true
    startStream()
  }

  func close() {
    streamGeneration += 1
    eventTask?.cancel()
    eventTask = nil
    ownedInspector?.close()
    ownedInspector = nil
    isOpen = false
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    events.removeAll()
    streamGeneration += 1
    eventTask?.cancel()
    eventTask = nil
    if isOpen { startStream() }
  }

  var consoleCount: Int { events.reduce(0) { $0 + (isConsole($1) ? 1 : 0) } }
  var networkCount: Int { events.count - consoleCount }

  private func isConsole(_ event: ShaarDevToolsEvent) -> Bool {
    if case .console = event { return true }
    return false
  }

  private func startStream() {
    let target = target
    let generation = streamGeneration
    eventTask = Task { [weak self, transport] in
      for await event in transport.events(for: target) {
        guard let self, self.isOpen, self.target == target,
          self.streamGeneration == generation
        else { return }
        self.events.append(event)
        if self.events.count > 2_000 { self.events.removeFirst(self.events.count - 2_000) }
      }
    }
  }

  isolated deinit { eventTask?.cancel() }
}

enum ShaarDevToolsSizing {
  static func bottom(_ desired: CGFloat, available: CGFloat) -> CGFloat {
    min(max(240, desired), max(240, available * 0.7))
  }

  static func right(_ desired: CGFloat, available: CGFloat) -> CGFloat {
    min(max(320, desired), max(320, available * 0.5))
  }
}
