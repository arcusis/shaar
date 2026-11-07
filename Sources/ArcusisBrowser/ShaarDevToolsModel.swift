// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

enum ShaarDevToolsSection: String, CaseIterable {
  case elements = "Elements"
  case components = "Components"
  case console = "Console"
  case issues = "Issues"
  case network = "Network"
  case application = "Application"
  case performance = "Performance"
  case memory = "Memory"
  case coverage = "Coverage"
  case audits = "Audits"
  case sources = "Sources"
  case cssOverview = "CSS overview"
  case security = "Security"
  case sensors = "Sensors"
  case repro = "Repro"
  case recorder = "Recorder"
  case viewports = "Viewports"
  case rendering = "Rendering"
  case comparison = "Comparison"
}

enum ShaarDevToolsDock: String, CaseIterable {
  case bottom = "Dock to bottom"
  case right = "Dock to right"
  case left = "Dock to left"
  case floating = "Open in separate window"
}

enum ShaarDevToolsNavigation {
  static func adjacentIndex(_ index: Int, count: Int, forward: Bool) -> Int? {
    guard count > 0 else { return nil }
    return min(count - 1, max(0, index + (forward ? 1 : -1)))
  }
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
  let usesPanelLease: Bool
  let origin: Origin
  let timestamp: Date

  init(
    id: UUID, level: Level, message: String, source: String?,
    stack: [ShaarConsoleFrame] = [], objectID: String? = nil,
    previewProperties: [ShaarConsoleProperty] = [], origin: Origin = .browser,
    timestamp: Date = Date(), usesPanelLease: Bool = false
  ) {
    self.id = id
    self.level = level
    self.message = message
    self.source = source
    self.stack = stack
    self.objectID = objectID
    self.previewProperties = previewProperties
    self.usesPanelLease = usesPanelLease
    self.origin = origin
    self.timestamp = timestamp
  }
}

struct ShaarConsoleFrame: Hashable, Sendable {
  let function: String
  let source: String
}

struct ShaarConsoleProperty: Equatable, Sendable {
  let name: String
  let value: String
  var objectID: String? = nil
}

struct ShaarNetworkEvent: Equatable, Sendable {
  enum Phase: Sendable {
    case request, response, data, finished, failed
    case webSocketCreated, webSocketHandshake, webSocketFrame, webSocketClosed
  }
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
  let frame: ShaarWebSocketFrame?

  init(
    id: UUID, method: String, url: String, status: Int?,
    requestID: String? = nil, phase: Phase = .finished,
    mimeType: String? = nil, encodedBytes: Int? = nil, time: TimeInterval = 0,
    failure: String? = nil, requestHeaders: [ShaarNetworkHeader] = [],
    responseHeaders: [ShaarNetworkHeader] = [], payload: String? = nil,
    responseBody: String? = nil, frame: ShaarWebSocketFrame? = nil
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
    self.frame = frame
  }
}

struct ShaarWebSocketFrame: Equatable, Sendable {
  enum Direction: Sendable { case sent, received }
  let direction: Direction
  let opcode: Int
  let payload: String
  let time: TimeInterval

  var display: String {
    switch opcode {
    case 1: payload
    case 2: "Binary frame"
    case 8: "Close"
    case 9: "Ping"
    case 10: "Pong"
    default: "Frame opcode \(opcode)"
    }
  }
}

struct ShaarNetworkHeader: Codable, Equatable, Sendable {
  var name: String
  var value: String
}

enum ShaarDevToolsEvent: Equatable, Sendable {
  case console(ShaarConsoleEvent)
  case network(ShaarNetworkEvent)
}

enum ShaarDevToolsTransportMessage: Equatable, Sendable {
  case streamAvailable
  case streamUnavailable
  case event(ShaarDevToolsEvent)
  case maskedFrame(Data)
}

@MainActor
protocol ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage>
}

enum ShaarLocalConsoleMessage {
  case available
  case unavailable
  case event(ShaarConsoleEvent)
}

@MainActor
protocol ShaarLocalConsoleTransport {
  var sourceID: String { get }
  var origin: ShaarConsoleEvent.Origin { get }
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarLocalConsoleMessage>
}

/// A pending transport reports unavailable when no native panel is connected.
struct ShaarDevToolsPendingTransport: ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamUnavailable)
      continuation.finish()
    }
  }
}

struct ShaarDevToolsEventBuffer {
  private(set) var events: [ShaarDevToolsEvent] = []
  private(set) var consoleCount = 0
  private(set) var networkCount = 0
  private(set) var droppedConsoleCount = 0
  private(set) var droppedNetworkCount = 0
  private(set) var retainedBytes = 0
  private var networkIDs: Set<String> = []
  private var networkEventCount = 0

  private static let limit = 50_000
  private static let trimCount = 1_000
  private static let networkEventLimit = 250_000
  private static let byteLimit = 64 * 1_048_576

  mutating func append(_ event: ShaarDevToolsEvent) {
    let bytes = Self.estimatedBytes(event)
    guard bytes <= Self.byteLimit else {
      switch event {
      case .console: droppedConsoleCount += 1
      case .network: droppedNetworkCount += 1
      }
      return
    }
    events.append(event)
    retainedBytes += bytes
    switch event {
    case .console:
      consoleCount += 1
      if consoleCount > Self.limit { trimConsole() }
    case .network(let request):
      networkEventCount += 1
      if networkIDs.insert(request.requestID).inserted { networkCount += 1 }
      if networkCount > Self.limit || networkEventCount > Self.networkEventLimit {
        trimNetworkRequests()
      }
    }
    while retainedBytes > Self.byteLimit, !events.isEmpty {
      switch events[0] {
      case .console: trimConsole()
      case .network: trimNetworkRequests()
      }
    }
  }

  mutating func removeConsole() {
    var removedBytes = 0
    events.removeAll { event in
      guard case .console = event else { return false }
      removedBytes += Self.estimatedBytes(event)
      return true
    }
    consoleCount = 0
    retainedBytes = max(0, retainedBytes - removedBytes)
  }

  mutating func clear() {
    events.removeAll()
    consoleCount = 0
    networkCount = 0
    droppedConsoleCount = 0
    droppedNetworkCount = 0
    retainedBytes = 0
    networkIDs.removeAll()
    networkEventCount = 0
  }

  private mutating func trimConsole() {
    var remaining = Self.trimCount
    var removedBytes = 0
    events.removeAll { event in
      guard remaining > 0 else { return false }
      guard case .console = event else { return false }
      remaining -= 1
      removedBytes += Self.estimatedBytes(event)
      return true
    }
    let removed = Self.trimCount - remaining
    consoleCount -= removed
    droppedConsoleCount += removed
    retainedBytes -= removedBytes
  }

  private mutating func trimNetworkRequests() {
    var ids: Set<String> = []
    for case .network(let event) in events {
      ids.insert(event.requestID)
      if ids.count == Self.trimCount { break }
    }
    guard !ids.isEmpty else { return }
    var removedBytes = 0
    var removedEvents = 0
    events.removeAll { event in
      guard case .network(let request) = event, ids.contains(request.requestID) else {
        return false
      }
      removedBytes += Self.estimatedBytes(event)
      removedEvents += 1
      return true
    }
    networkIDs.subtract(ids)
    networkCount -= ids.count
    networkEventCount -= removedEvents
    droppedNetworkCount += ids.count
    retainedBytes -= removedBytes
  }

  private static func estimatedBytes(_ event: ShaarDevToolsEvent) -> Int {
    switch event {
    case .console(let entry):
      let frames = entry.stack.reduce(0) { $0 + $1.function.utf8.count + $1.source.utf8.count }
      let properties = entry.previewProperties.reduce(0) {
        $0 + $1.name.utf8.count + $1.value.utf8.count
      }
      return 128 + entry.message.utf8.count + (entry.source?.utf8.count ?? 0)
        + (entry.objectID?.utf8.count ?? 0) + frames + properties
    case .network(let request):
      let headers = (request.requestHeaders + request.responseHeaders).reduce(0) {
        $0 + $1.name.utf8.count + $1.value.utf8.count
      }
      return 192 + request.requestID.utf8.count + request.method.utf8.count
        + request.url.utf8.count + (request.mimeType?.utf8.count ?? 0)
        + (request.failure?.utf8.count ?? 0) + (request.payload?.utf8.count ?? 0)
        + (request.responseBody?.utf8.count ?? 0)
        + (request.frame?.payload.utf8.count ?? 0) + headers
    }
  }
}

@MainActor @Observable
final class ShaarDevToolsModel {
  private(set) var target: SiteControlTarget
  private(set) var isOpen = false
  var section: ShaarDevToolsSection = .elements {
    didSet {
      if section == .comparison && !allowsWebKitComparison {
        section = oldValue
        return
      }
      rememberSectionIfNeeded()
      guard isOpen, section != oldValue else { return }
      if section == .viewports { viewports.open() } else { viewports.close() }
      if section == .elements { dom.open() } else { dom.close() }
      if section == .components { framework.activate() } else { framework.suspend() }
      if section == .comparison {
        comparison.open(inspector: comparisonInspector)
      } else {
        comparison.close()
      }
    }
  }
  var dock: ShaarDevToolsDock = .right {
    didSet {
      layoutDefaults.set(dock.rawValue, forKey: "shaar.devtools.dock")
      if oldValue == .floating && dock != .floating {
        floatingWindow?.dismiss()
        floatingWindow = nil
      }
    }
  }
  var bottomHeight: CGFloat = 380 {
    didSet { layoutDefaults.set(Double(bottomHeight), forKey: "shaar.devtools.bottomHeight") }
  }
  var rightWidth: CGFloat = 420 {
    didSet { layoutDefaults.set(Double(rightWidth), forKey: "shaar.devtools.rightWidth") }
  }
  var leftWidth: CGFloat = 420 {
    didSet { layoutDefaults.set(Double(leftWidth), forKey: "shaar.devtools.leftWidth") }
  }
  var commandMenuOpen = false
  var settingsOpen = false
  var commandQuery = "" {
    didSet {
      guard commandQuery != oldValue else { return }
      commandSelection = 0
    }
  }
  var commandSelection = 0
  @ObservationIgnored private let layoutDefaults: UserDefaults
  @ObservationIgnored var floatingWindow: ShaarDevToolsFloatingWindow?
  private(set) var streamAvailable = false
  private var eventBuffer = ShaarDevToolsEventBuffer()
  @ObservationIgnored private var navigationResetPending = false
  var events: [ShaarDevToolsEvent] { eventBuffer.events }
  var droppedConsoleCount: Int { eventBuffer.droppedConsoleCount }
  var droppedNetworkCount: Int { eventBuffer.droppedNetworkCount }
  private(set) var localEventsBySource: [String: [ShaarConsoleEvent]] = [:]
  private(set) var localAvailableSources: Set<String> = []
  let console = ShaarConsoleModel()
  let network = ShaarNetworkModel()
  let rules: ShaarNetworkRulesModel
  let dom: ShaarDOMTreeModel
  let listeners: ShaarEventListenersModel
  let phase2: ShaarPhase2Model
  let application: ShaarApplicationModel
  let cookies = ShaarCookieModel()
  let performance: ShaarPerformanceModel
  let memory: ShaarMemoryModel
  let coverage = ShaarDevToolsCoverageModel()
  let sources: ShaarSourcesModel
  let cssOverview: ShaarDevToolsCSSOverviewModel
  let repro: ShaarReproModel
  let recorder = ShaarDevToolsRecorderModel()
  let viewports: ShaarViewportsModel
  let rendering: ShaarRenderingModel
  let framework = ShaarFrameworkComponentsModel()
  let comparison: ShaarWebKitComparisonModel
  let pageAudit = InspectorAuditModel(inspector: nil)
  private var auditFixture: AuditFixture?
  let allowsWebKitComparison: Bool
  var securitySummary: ShaarDevToolsSecuritySummary
  @ObservationIgnored var loadSecurity:
    (@MainActor (SiteControlTarget) async -> ShaarDevToolsSecuritySummary)?
  @ObservationIgnored var presentCertificate: @MainActor () -> Void = {}
  @ObservationIgnored private var securityGeneration = 0
  var sensorLocation: ShaarDevToolsSensorLocation = .system
  var sensorLatitude = ""
  var sensorLongitude = ""
  var sensorAccuracy = ""
  var sensorTimezone: ShaarDevToolsSensorTimezone = .system
  var sensorLocale: ShaarDevToolsSensorLocale = .system
  var sensorTouch = false
  /// Turned on when a probe shows the engine accepts Emulation.setTouchEmulationEnabled.
  var sensorTouchReady = false
  var sensorIdle: ShaarDevToolsSensorIdle = .system
  /// Turned on when a probe shows the engine accepts Emulation.clearIdleOverride.
  var sensorIdleReady = false
  var sensorNotice: ShaarDevToolsSensorNotice?
  @ObservationIgnored var touchProbeFinished = false
  @ObservationIgnored var touchProbeInFlight = false
  @ObservationIgnored var idleProbeFinished = false
  @ObservationIgnored var idleProbeInFlight = false
  @ObservationIgnored var sensorFixture: (@MainActor (ShaarDevToolsSensorCommand) -> Void)?
  @ObservationIgnored var sendSensorCommand:
    (@MainActor (ShaarDevToolsSensorCommand) async throws -> Void)?
  @ObservationIgnored weak var sensorEngine: BrowserEngine?
  @ObservationIgnored var sensorGeneration = 0
  var sections: [ShaarDevToolsSection] {
    ShaarDevToolsSection.allCases.filter { $0 != .comparison || allowsWebKitComparison }
  }
  @ObservationIgnored private let transport: any ShaarDevToolsEventTransport
  @ObservationIgnored private var localTransports: [String: any ShaarLocalConsoleTransport]
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var localTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var localTokens: [String: UUID] = [:]
  @ObservationIgnored private var streamGeneration = 0
  @ObservationIgnored private var ownedInspector: InspectorModel?
  @ObservationIgnored private var frameworkClose: Task<Void, Never>?
  @ObservationIgnored private weak var comparisonInspector: InspectorModel?

  init(
    target: SiteControlTarget,
    transport: any ShaarDevToolsEventTransport = ShaarDevToolsPendingTransport(),
    phase2Transport: any ShaarPhase2Transport = ShaarPhase2PendingTransport(),
    sourceInspectorContent: ShaarSourcesModel.InspectorContent? = nil,
    sourceLoader: @escaping @Sendable (URL) async throws -> Data = DevelopmentSourceHTTP.load,
    reproTransport: any ShaarReproTransport = ShaarReproPendingTransport(),
    viewportsTransport: any ShaarViewportsTransport = ShaarViewportsPendingTransport(),
    renderingTransport: any ShaarRenderingTransport = ShaarRenderingPendingTransport(),
    localTransports: [any ShaarLocalConsoleTransport] = [],
    rulesTransport: any ShaarNetworkRulesTransport = ShaarNetworkRulesPendingTransport(),
    domTransport: any ShaarDOMTransport = ShaarDOMPendingTransport(),
    listenersTransport: any ShaarEventListenersTransport = ShaarEventListenersPendingTransport(),
    rulesStore: ShaarNetworkRuleStore = ShaarNetworkRuleStore(),
    layoutDefaults: UserDefaults = .standard,
    allowsWebKitComparison: Bool = false,
    comparisonPreview: ShaarWebKitComparisonPreview? = nil,
    memoryTransport: any ShaarMemoryTransport = ShaarMemoryPendingTransport()
  ) {
    self.target = target
    securitySummary = ShaarDevToolsSecuritySummary.make(
      url: target.url, engineLevel: nil, certificate: nil)
    self.allowsWebKitComparison = allowsWebKitComparison
    comparison = ShaarWebKitComparisonModel(target: target, preview: comparisonPreview)
    self.layoutDefaults = layoutDefaults
    if let saved = layoutDefaults.string(forKey: "shaar.devtools.dock"),
      let dock = ShaarDevToolsDock(rawValue: saved)
    {
      self.dock = dock
    }
    bottomHeight = Self.savedSize(
      "shaar.devtools.bottomHeight", fallback: ShaarDevToolsMetrics.bottomHeight, in: layoutDefaults
    )
    rightWidth = Self.savedSize(
      "shaar.devtools.rightWidth", fallback: ShaarDevToolsMetrics.sideWidth, in: layoutDefaults)
    leftWidth = Self.savedSize(
      "shaar.devtools.leftWidth", fallback: ShaarDevToolsMetrics.sideWidth, in: layoutDefaults)
    self.transport = transport
    self.localTransports = Dictionary(
      uniqueKeysWithValues: localTransports.map { ($0.sourceID, $0) })
    rules = ShaarNetworkRulesModel(
      target: target, store: rulesStore, transport: rulesTransport)
    let domModel = ShaarDOMTreeModel(target: target, transport: domTransport)
    dom = domModel
    if let live = listenersTransport as? ShaarEventListenersLiveTransport {
      live.rebind = { [weak domModel] ids, target in
        guard let domModel, domModel.target == target else { return [:] }
        return await domModel.rebindFrontendIDs(ids)
      }
    }
    listeners = ShaarEventListenersModel(target: target, transport: listenersTransport)
    let phase2 = ShaarPhase2Model(target: target, transport: phase2Transport)
    self.phase2 = phase2
    application = ShaarApplicationModel(phase2: phase2)
    performance = ShaarPerformanceModel(target: target, phase2: phase2)
    memory = ShaarMemoryModel(transport: memoryTransport)
    sources = ShaarSourcesModel(
      phase2: phase2, inspectorContent: sourceInspectorContent,
      loadSourceData: sourceLoader)
    cssOverview = ShaarDevToolsCSSOverviewModel(sources: sources)
    repro = ShaarReproModel(target: target, transport: reproTransport)
    viewports = ShaarViewportsModel(target: target, transport: viewportsTransport)
    rendering = ShaarRenderingModel(target: target, transport: renderingTransport)
    framework.updateAccess(url: target.url)
    section = resolvedOpeningSection()
    console.onClear = { [weak self] in
      self?.eventBuffer.removeConsole()
    }
    console.loadProperties = { [weak self] objectID in
      guard let self, let transport = self.transport as? ShaarDevToolsNativeTransport else {
        throw ShaarConsoleEvaluationError(message: "Console object is unavailable.")
      }
      return try await transport.consoleProperties(objectID: objectID, for: self.target)
    }
    network.loadBody = { [weak self] requestID in
      guard let self, let transport = self.transport as? ShaarDevToolsNativeTransport else {
        throw ShaarNetworkBodyError.unavailable
      }
      return try await transport.responseBody(requestID: requestID, for: self.target)
    }
  }

  private static func savedSize(_ key: String, fallback: CGFloat, in defaults: UserDefaults)
    -> CGFloat
  {
    guard defaults.object(forKey: key) != nil else { return fallback }
    let size = CGFloat(defaults.double(forKey: key))
    return size.isFinite && size > 0 ? size : fallback
  }

  func open(inspector: InspectorModel) {
    guard !isOpen else { return }
    applyPinnedOpeningSection()
    frameworkClose?.cancel()
    frameworkClose = nil
    comparisonInspector = inspector
    attachCSSPageSheets(inspector)
    pageAudit.inspector = inspector
    attachSensorSender(inspector)
    coverage.attach(inspector, target: target)
    recorder.attach(inspector)
    if !inspector.isOpen {
      inspector.open()
      ownedInspector = inspector
    }
    isOpen = true
    framework.attach(inspector)
    framework.updateAccess(url: target.url)
    repro.history.start(for: target)
    repro.startFrames(for: target)
    startStream()
    startLocalStreams()
    phase2.open()
    if section == .viewports { viewports.open() }
    rules.resume()
    if section == .elements { dom.open() }
    if section == .components { framework.activate() }
    if section == .comparison && allowsWebKitComparison { comparison.open(inspector: inspector) }
  }

  func close() {
    floatingWindow?.dismiss()
    floatingWindow = nil
    streamGeneration += 1
    eventTask?.cancel()
    eventTask = nil
    cancelLocalTasks()
    streamAvailable = false
    repro.history.stop()
    repro.stopFrames()
    eventBuffer.clear()
    navigationResetPending = false
    localEventsBySource.removeAll()
    localAvailableSources.removeAll()
    console.clearEntries()
    network.resetLog()
    rules.close()
    phase2.close()
    viewports.close()
    rendering.restore()
    comparison.close()
    comparisonInspector = nil
    dom.close()
    application.reset()
    cookies.reset()
    performance.reset()
    memory.reset()
    coverage.detach()
    sources.reset()
    cssOverview.reset()
    recorder.detach()
    pageAudit.reset()
    pageAudit.inspector = nil
    auditFixture = nil
    let inspector = ownedInspector
    ownedInspector = nil
    // The component highlight still needs this page. Stop presenting now so
    // ownership is restored before the highlight clear finishes.
    inspector?.stopPresenting()
    let hide = framework.beginHide()
    frameworkClose?.cancel()
    frameworkClose = Task { @MainActor in
      await framework.finishHide(epoch: hide.epoch, attachment: hide.attachment)
      guard !Task.isCancelled, !isOpen else { return }
      inspector?.close()
    }
    closeCommandMenu()
    closeSettings()
    resetSensors()
    isOpen = false
  }

  func toggleCommandMenu() {
    if commandMenuOpen {
      closeCommandMenu()
    } else {
      closeSettings()
      commandMenuOpen = true
      commandQuery = ""
      commandSelection = 0
    }
  }

  func closeCommandMenu() {
    commandMenuOpen = false
    commandQuery = ""
    commandSelection = 0
  }

  var commandMatches: [ShaarDevToolsCommandMatch] {
    let entries = consoleEvents.compactMap { event -> ShaarConsoleEvent? in
      guard case .console(let entry) = event else { return nil }
      return entry
    }
    return ShaarDevToolsCommandIndex.matches(
      query: commandQuery, sections: sections, console: entries,
      network: network.requests(from: events), sources: sources.resources,
      nodes: Array(dom.nodes.values))
  }

  var clampedCommandSelection: Int {
    let count = commandMatches.count
    guard count > 0 else { return 0 }
    return min(commandSelection, count - 1)
  }

  func moveCommandSelection(forward: Bool) {
    let count = commandMatches.count
    guard count > 0 else { return }
    let next = commandSelection + (forward ? 1 : -1)
    commandSelection = min(count - 1, max(0, next))
  }

  var issues: [ShaarDevToolsIssue] {
    let console = consoleEvents.compactMap { event -> ShaarConsoleEvent? in
      if case .console(let entry) = event { return entry }
      return nil
    }
    return ShaarDevToolsIssues.list(console: console, requests: network.requests(from: events))
  }

  func openIssue(_ issue: ShaarDevToolsIssue) {
    switch issue.kind {
    case .console(let id, _):
      section = .console
      console.level = nil
      console.origin = nil
      console.search = ""
      console.selectedID = id
    case .network(let id, _, _):
      section = .network
      network.filter = .all
      network.search = ""
      network.selectedID = id
    }
  }

  func performSelectedCommand() {
    let matches = commandMatches
    guard matches.indices.contains(clampedCommandSelection) else { return }
    perform(matches[clampedCommandSelection])
  }

  func perform(_ match: ShaarDevToolsCommandMatch) {
    closeCommandMenu()
    switch match.hit {
    case .section(let section):
      self.section = section
    case .dock(let dock):
      self.dock = dock
    case .console(let id):
      section = .console
      console.level = nil
      console.origin = nil
      console.search = ""
      console.selectedID = id
    case .network(let id):
      section = .network
      network.filter = .all
      network.search = ""
      network.selectedID = id
    case .source(let url):
      section = .sources
      sources.search = ""
      guard let resource = sources.resources.first(where: { $0.url == url }) else { return }
      let sources = sources
      Task { await sources.select(resource) }
    case .element(let id):
      section = .elements
      dom.search = ""
      dom.select(id)
    case .settings:
      showSettings()
    }
  }

  var opening: ShaarDevToolsOpening { ShaarDevToolsOpening.load(layoutDefaults) }

  func chooseOpening(_ opening: ShaarDevToolsOpening) {
    layoutDefaults.set(opening.storageValue, forKey: ShaarDevToolsOpening.key)
    switch opening {
    case .last:
      layoutDefaults.set(section.rawValue, forKey: ShaarDevToolsOpening.lastSectionKey)
    case .panel:
      section = resolvedOpeningSection()
    }
  }

  func restoreDefaultDockSizes() {
    bottomHeight = ShaarDevToolsMetrics.bottomHeight
    rightWidth = ShaarDevToolsMetrics.sideWidth
    leftWidth = ShaarDevToolsMetrics.sideWidth
  }

  func showSettings() {
    closeCommandMenu()
    settingsOpen = true
  }

  func closeSettings() {
    settingsOpen = false
  }

  func resolvedOpeningSection() -> ShaarDevToolsSection {
    let candidate = openingCandidate(opening)
    guard sections.contains(candidate) else { return .elements }
    return candidate
  }

  private func applyPinnedOpeningSection() {
    guard case .panel = opening else { return }
    section = resolvedOpeningSection()
  }

  private func rememberSectionIfNeeded() {
    guard opening == .last else { return }
    layoutDefaults.set(section.rawValue, forKey: ShaarDevToolsOpening.lastSectionKey)
  }

  private func openingCandidate(_ opening: ShaarDevToolsOpening) -> ShaarDevToolsSection {
    switch opening {
    case .last:
      let saved = layoutDefaults.string(forKey: ShaarDevToolsOpening.lastSectionKey) ?? ""
      return ShaarDevToolsSection(rawValue: saved) ?? .elements
    case .panel(let panel):
      return panel
    }
  }

  private func attachCSSPageSheets(_ inspector: InspectorModel) {
    cssOverview.attach { [weak inspector] in
      guard let inspector else { return [] }
      let value = try await inspector.evaluate(ShaarDevToolsCSSOverview.pageSheetExpression)
      return ShaarDevToolsCSSOverview.sheets(fromPage: value)
    }
  }

  func beginNavigation() {
    guard !navigationResetPending else { return }
    retainConsoleIfRequested()
    eventBuffer.clear()
    network.resetLog()
    navigationResetPending = true
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    let tabChanged = self.target.tabID != target.tabID
    if self.target.host != target.host { disconnectLogTap() }
    self.target = target
    performance.updateTarget(target, committed: committed)
    // The panel lease is attached to the tab, and it stays up across a reload.
    // Closing it here drops the new document's console and network events,
    // which fire while the replacement lease is still opening.
    let keepLease = !tabChanged && eventTask != nil
    let keepNavigationEvents = navigationResetPending && keepLease
    if !keepLease {
      streamAvailable = false
      localEventsBySource.removeAll()
      localAvailableSources.removeAll()
    }
    repro.history.stop()
    repro.stopFrames()
    if !keepNavigationEvents {
      retainConsoleIfRequested()
      eventBuffer.clear()
      network.resetLog()
    }
    if committed || tabChanged { navigationResetPending = false }
    rules.updateTarget(target, committed: committed)
    phase2.updateTarget(target, committed: committed)
    viewports.updateTarget(target, committed: committed)
    rendering.updateTarget(target, committed: committed)
    comparison.updateTarget(target, committed: committed)
    dom.updateTarget(target, committed: committed)
    listeners.updateTarget(target)
    application.reset()
    cookies.reset()
    sources.reset()
    cssOverview.reset()
    if committed || tabChanged {
      Task { [weak self] in
        await self?.cssOverview.reload(force: true)
      }
    }
    memory.reset()
    coverage.retarget(target)
    recorder.retarget(tabChanged: tabChanged, committed: committed)
    pageAudit.reset()
    auditFixture = nil
    framework.updateAccess(url: target.url)
    replaceSecuritySummary()
    if tabChanged { resetSensorForm() }
    closeCommandMenu()
    closeSettings()
    repro.updateTarget(target, committed: committed)
    if !keepLease {
      streamGeneration += 1
      eventTask?.cancel()
      eventTask = nil
      cancelLocalTasks()
    }
    if isOpen {
      repro.history.start(for: target)
      repro.startFrames(for: target)
      if !keepLease {
        startStream()
        startLocalStreams()
      }
      rules.resume()
    }
  }

  private struct AuditFixture {
    var report: InspectorAuditModel.Report?
    var budget: ShaarPerformanceBudgetResult?
  }

  var auditCounts: ShaarDevToolsAuditCounts {
    ShaarDevToolsAuditCounts.make(report: displayedAuditReport, budget: displayedAuditBudget)
  }

  var auditRows: [ShaarDevToolsAuditRow] {
    ShaarDevToolsAudits.rows(from: displayedAuditReport)
  }

  var auditRoute: String? { displayedAuditBudget?.route }

  var auditFailure: String? {
    if auditFixture != nil { return nil }
    return pageAudit.failure
  }

  var auditBusy: Bool {
    if auditFixture != nil { return false }
    return pageAudit.busy
  }

  func presentAuditFixture(
    report: InspectorAuditModel.Report?, budget: ShaarPerformanceBudgetResult?
  ) {
    auditFixture = AuditFixture(report: report, budget: budget)
  }

  func openAuditFinding(_ id: String) {
    guard let finding = pageAudit.report?.findings.first(where: { $0.id == id }) else { return }
    pageAudit.select(finding)
  }

  private var displayedAuditReport: InspectorAuditModel.Report? {
    if let auditFixture { return auditFixture.report }
    return pageAudit.report
  }

  private var displayedAuditBudget: ShaarPerformanceBudgetResult? {
    if let auditFixture { return auditFixture.budget }
    return performance.budgetResult
  }

  var securityReloadToken: String {
    "\(securityGeneration)|\(target.url.absoluteString)"
  }

  func refreshSecurity() async {
    guard let loadSecurity else { return }
    let generation = securityGeneration
    let requested = target
    let summary = await loadSecurity(requested)
    guard generation == securityGeneration, target == requested else { return }
    securitySummary = summary
  }

  private func replaceSecuritySummary() {
    securityGeneration += 1
    securitySummary = ShaarDevToolsSecuritySummary.make(
      url: target.url, engineLevel: nil, certificate: nil)
  }

  func refreshFrameworkComponents() {
    guard isOpen, section == .components else { return }
    framework.activate()
  }

  /// The document-commit read can run before the parser inserts style sheets
  /// and before the new document's DOM node ids are bound.
  /// Read again once the page has finished loading.
  func pageDidFinishLoading() {
    guard isOpen else { return }
    Task { [weak self] in
      await self?.cssOverview.reload(force: true)
      guard let self else { return }
      await self.dom.loadDocument()
      await self.listeners.refresh()
    }
  }

  var localConsoleEvents: [ShaarConsoleEvent] {
    localEventsBySource.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
  }
  var consoleAvailable: Bool { streamAvailable || !localAvailableSources.isEmpty }
  var consoleEvents: [ShaarDevToolsEvent] {
    events + localConsoleEvents.map(ShaarDevToolsEvent.console)
  }
  var consoleCount: Int {
    eventBuffer.consoleCount + localConsoleEvents.count
  }
  var networkCount: Int { eventBuffer.networkCount }
  var nativeRecordingFailure: String? {
    (transport as? ShaarDevToolsNativeTransport)?.recordingFailure
  }
  var nativeStreamFailure: String? {
    (transport as? ShaarDevToolsNativeTransport)?.failure
  }
  var nativePhase2Failure: String? {
    (transport as? ShaarDevToolsNativeTransport)?.phase2Failure
  }
  var nativeRecordingStarting: Bool {
    (transport as? ShaarDevToolsNativeTransport)?.recordingStarting ?? false
  }

  /// The repro mask deletes its style node once the page grows past 2000 elements.
  func releasePageMask() async {
    await (transport as? ShaarDevToolsNativeTransport)?.releaseRecording()
    repro.stopFrames()
  }

  var canTapLocalLogs: Bool {
    DevelopmentModePreference.isEnabled
      && DevelopmentPage.detect(url: target.url).isDevelopmentPage
  }

  var hasLogTap: Bool { localTransports["fileLogTap"] != nil }

  @discardableResult
  func connectLogTap(_ file: URL) -> Bool {
    guard canTapLocalLogs, file.isFileURL,
      FileManager.default.fileExists(atPath: file.path)
    else { return false }
    disconnectLogTap()
    let transport = ShaarFileLogTapTransport(file: file.standardizedFileURL)
    localTransports[transport.sourceID] = transport
    if isOpen { startLocalStream(transport) }
    return true
  }

  func disconnectLogTap() {
    let id = "fileLogTap"
    localTasks[id]?.cancel()
    localTasks[id] = nil
    localTokens[id] = nil
    localTransports[id] = nil
    localAvailableSources.remove(id)
    localEventsBySource[id] = nil
  }

  private func startStream() {
    let target = target
    let generation = streamGeneration
    eventTask = Task { [weak self, transport] in
      for await message in transport.messages(for: target) {
        guard let self, self.isOpen, self.target.sharesPanelTab(with: target),
          self.streamGeneration == generation
        else { return }
        self.receive(message)
      }
    }
  }

  private func startLocalStreams() {
    for transport in localTransports.values { startLocalStream(transport) }
  }

  private func startLocalStream(_ transport: any ShaarLocalConsoleTransport) {
    let target = target
    let generation = streamGeneration
    let id = transport.sourceID
    let token = UUID()
    localTokens[id] = token
    let task = Task { [weak self] in
      for await message in transport.messages(for: target) {
        guard let self, self.isOpen, self.target.sharesPanelTab(with: target),
          self.streamGeneration == generation, self.localTokens[id] == token
        else { return }
        self.receiveLocal(message, from: transport)
      }
    }
    localTasks[id] = task
  }

  private func cancelLocalTasks() {
    for task in localTasks.values { task.cancel() }
    localTasks.removeAll()
    localTokens.removeAll()
  }

  private func receiveLocal(
    _ message: ShaarLocalConsoleMessage, from transport: any ShaarLocalConsoleTransport
  ) {
    let id = transport.sourceID
    switch message {
    case .available: localAvailableSources.insert(id)
    case .unavailable:
      localAvailableSources.remove(id)
      localEventsBySource[id] = nil
    case .event(let event):
      guard localAvailableSources.contains(id), event.origin == transport.origin else { return }
      localEventsBySource[id, default: []].append(event)
      if localEventsBySource[id, default: []].count > 500 {
        localEventsBySource[id]?.removeFirst()
      }
    }
  }

  private func retainConsoleIfRequested() {
    if console.preserveLog {
      console.retain(from: consoleEvents)
    } else {
      console.clearEntries()
    }
  }

  private func receive(_ message: ShaarDevToolsTransportMessage) {
    switch message {
    case .streamAvailable:
      streamAvailable = true
      if !repro.frames.isActive { repro.startFrames(for: target) }
    case .streamUnavailable:
      streamAvailable = false
      repro.history.clear()
      repro.stopFrames()
      retainConsoleIfRequested()
      eventBuffer.clear()
      network.resetLog()
    case .event(let event):
      guard streamAvailable else { return }
      repro.history.record(event, for: target)
      eventBuffer.append(event)
    case .maskedFrame(let jpeg):
      guard streamAvailable else { return }
      repro.receiveMaskedFrame(jpeg)
    }
  }

  func receiveNativePanelEvent(
    tabID: String, profileID: String, payload: Data, sequence: UInt64
  ) {
    (transport as? ShaarDevToolsNativeTransport)?.receive(
      tabID: tabID, profileID: profileID, payload: payload, sequence: sequence)
  }

  isolated deinit {
    eventTask?.cancel()
    cancelLocalTasks()
  }
}

enum ShaarDevToolsSizing {
  static func bottom(_ desired: CGFloat, available: CGFloat) -> CGFloat {
    min(max(240, desired), max(240, available * 0.7))
  }

  static func right(_ desired: CGFloat, available: CGFloat) -> CGFloat {
    min(max(320, desired), max(320, available * 0.5))
  }

  static func side(_ desired: CGFloat, available: CGFloat) -> CGFloat {
    let maximum = max(160, min(available * 0.5, available - 180))
    return min(max(min(320, maximum), desired), maximum)
  }
}
