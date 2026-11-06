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
  let stack: [ShaarConsoleFrame]
  let objectID: String?
  let previewProperties: [ShaarConsoleProperty]

  init(
    id: UUID, level: Level, message: String, source: String?,
    stack: [ShaarConsoleFrame] = [], objectID: String? = nil,
    previewProperties: [ShaarConsoleProperty] = []
  ) {
    self.id = id
    self.level = level
    self.message = message
    self.source = source
    self.stack = stack
    self.objectID = objectID
    self.previewProperties = previewProperties
  }
}

struct ShaarConsoleFrame: Hashable, Sendable {
  let function: String
  let source: String
}

struct ShaarConsoleProperty: Equatable, Sendable {
  let name: String
  let value: String
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

enum ShaarDevToolsTransportMessage: Equatable, Sendable {
  case streamAvailable
  case streamUnavailable
  case event(ShaarDevToolsEvent)
}

@MainActor
protocol ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage>
}

/// Production stays unavailable until shaar.17 reports its live panel capability.
struct ShaarDevToolsPendingTransport: ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamUnavailable)
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
  private(set) var streamAvailable = false
  private(set) var events: [ShaarDevToolsEvent] = []
  let console = ShaarConsoleModel()
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
    streamAvailable = false
    events.removeAll()
    console.clearEntries()
    ownedInspector?.close()
    ownedInspector = nil
    isOpen = false
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    streamAvailable = false
    events.removeAll()
    console.clearEntries()
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
      for await message in transport.messages(for: target) {
        guard let self, self.isOpen, self.target == target,
          self.streamGeneration == generation
        else { return }
        self.receive(message)
      }
    }
  }

  private func receive(_ message: ShaarDevToolsTransportMessage) {
    switch message {
    case .streamAvailable: streamAvailable = true
    case .streamUnavailable:
      streamAvailable = false
      events.removeAll()
      console.clearEntries()
    case .event(let event):
      guard streamAvailable else { return }
      events.append(event)
      if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
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
