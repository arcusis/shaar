// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarDevToolsSection: String, CaseIterable {
  case elements = "Elements"
  case console = "Console"
  case network = "Network"
  case application = "Application"
  case performance = "Performance"
  case sources = "Sources"
  case repro = "Repro"
  case viewports = "Viewports"
}

enum ShaarDevToolsDock: String, CaseIterable {
  case bottom = "Dock to bottom"
  case right = "Dock to right"
}

struct ShaarConsoleEvent: Equatable, Sendable {
  enum Level: String, Sendable { case log, info, warning, error }
  enum Origin: String, CaseIterable, Sendable {
    case browser = "Browser"
    case server = "Server"
    case spotlight = "Spotlight"
  }
  let id: UUID
  let level: Level
  let message: String
  let source: String?
  let stack: [ShaarConsoleFrame]
  let objectID: String?
  let previewProperties: [ShaarConsoleProperty]
  let origin: Origin

  init(
    id: UUID, level: Level, message: String, source: String?,
    stack: [ShaarConsoleFrame] = [], objectID: String? = nil,
    previewProperties: [ShaarConsoleProperty] = [], origin: Origin = .browser
  ) {
    self.id = id
    self.level = level
    self.message = message
    self.source = source
    self.stack = stack
    self.objectID = objectID
    self.previewProperties = previewProperties
    self.origin = origin
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
  enum Phase: Sendable { case request, response, data, finished, failed }
  let id: UUID
  let requestID: String
  let phase: Phase
  let method: String
  let url: String
  let status: Int?
  let mimeType: String?
  let encodedBytes: Int?
  let time: TimeInterval
  let failure: String?
  let requestHeaders: [ShaarNetworkHeader]
  let responseHeaders: [ShaarNetworkHeader]
  let payload: String?
  let responseBody: String?

  init(
    id: UUID, method: String, url: String, status: Int?,
    requestID: String? = nil, phase: Phase = .finished,
    mimeType: String? = nil, encodedBytes: Int? = nil, time: TimeInterval = 0,
    failure: String? = nil, requestHeaders: [ShaarNetworkHeader] = [],
    responseHeaders: [ShaarNetworkHeader] = [], payload: String? = nil,
    responseBody: String? = nil
  ) {
    self.id = id
    self.requestID = requestID ?? id.uuidString
    self.phase = phase
    self.method = method
    self.url = url
    self.status = status
    self.mimeType = mimeType
    self.encodedBytes = encodedBytes
    self.time = time
    self.failure = failure
    self.requestHeaders = requestHeaders
    self.responseHeaders = responseHeaders
    self.payload = payload
    self.responseBody = responseBody
  }
}

struct ShaarNetworkHeader: Equatable, Sendable {
  let name: String
  let value: String
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
  let network = ShaarNetworkModel()
  let phase2: ShaarPhase2Model
  let application: ShaarApplicationModel
  let cookies = ShaarCookieModel()
  let performance: ShaarPerformanceModel
  let sources: ShaarSourcesModel
  let repro: ShaarReproModel
  let viewports: ShaarViewportsModel
  @ObservationIgnored private let transport: any ShaarDevToolsEventTransport
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var streamGeneration = 0
  @ObservationIgnored private var ownedInspector: InspectorModel?

  init(
    target: SiteControlTarget,
    transport: any ShaarDevToolsEventTransport = ShaarDevToolsPendingTransport(),
    phase2Transport: any ShaarPhase2Transport = ShaarPhase2PendingTransport(),
    sourceLoader: @escaping @Sendable (URL) async throws -> Data = DevelopmentSourceHTTP.load,
    reproTransport: any ShaarReproTransport = ShaarReproPendingTransport(),
    viewportsTransport: any ShaarViewportsTransport = ShaarViewportsPendingTransport()
  ) {
    self.target = target
    self.transport = transport
    let phase2 = ShaarPhase2Model(target: target, transport: phase2Transport)
    self.phase2 = phase2
    application = ShaarApplicationModel(phase2: phase2)
    performance = ShaarPerformanceModel(target: target, phase2: phase2)
    sources = ShaarSourcesModel(phase2: phase2, loadSourceData: sourceLoader)
    repro = ShaarReproModel(target: target, transport: reproTransport)
    viewports = ShaarViewportsModel(target: target, transport: viewportsTransport)
  }

  func open(inspector: InspectorModel) {
    guard !isOpen else { return }
    if !inspector.isOpen {
      inspector.open()
      ownedInspector = inspector
    }
    isOpen = true
    startStream()
    phase2.open()
    viewports.open()
  }

  func close() {
    streamGeneration += 1
    eventTask?.cancel()
    eventTask = nil
    streamAvailable = false
    events.removeAll()
    console.clearEntries()
    network.clearSelection()
    phase2.close()
    viewports.close()
    application.reset()
    cookies.reset()
    performance.reset()
    sources.reset()
    ownedInspector?.close()
    ownedInspector = nil
    isOpen = false
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    performance.updateTarget(target, committed: committed)
    streamAvailable = false
    events.removeAll()
    console.clearEntries()
    network.clearSelection()
    phase2.updateTarget(target, committed: committed)
    viewports.updateTarget(target, committed: committed)
    application.reset()
    cookies.reset()
    sources.reset()
    repro.updateTarget(target, committed: committed)
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
      network.clearSelection()
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
