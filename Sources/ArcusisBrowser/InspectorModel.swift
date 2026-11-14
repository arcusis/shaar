// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Observation

@MainActor @Observable
final class InspectorModel {
  enum Mode { case closed, picking, locked }
  private(set) var target: SiteControlTarget
  private(set) var mode = Mode.closed
  private(set) var selection: InspectorSelection?
  private(set) var failure: String?
  private(set) var readingFonts = false
  private(set) var pageFontsTruncated = false
  var colorFormat = InspectorColor.Format.hex
  enum Tab: String, CaseIterable {
    case design = "Design"
    case styles = "Code"
    case component = "Component"
    case accessibility = "A11y"
    case assets = "Assets"
    case notes = "Notes"
  }
  enum PanelMode: String, CaseIterable {
    case element = "Element"
    case page = "Page"
  }
  private(set) var panelMode = PanelMode.element
  private(set) var pageTools: InspectorPageToolsModel?
  var tab = Tab.design
  let presentation = InspectorPresentation()
  @ObservationIgnored lazy var styles = InspectorStylesModel(inspector: self)
  @ObservationIgnored lazy var details = InspectorDetailsModel(inspector: self)
  @ObservationIgnored lazy var layout = InspectorLayoutModel(inspector: self)
  @ObservationIgnored lazy var aiCopy = InspectorAICopyModel(inspector: self)
  @ObservationIgnored lazy var sourceActions = InspectorSourceActions(inspector: self)
  var documentGeneration: Int { generation }
  var isOpen: Bool { mode != .closed }
  @ObservationIgnored weak var engine: BrowserEngine?
  @ObservationIgnored private let connection: InspectorConnection?
  var supportsPageTools: Bool { connection?.contextID == nil }
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var installed = false
  @ObservationIgnored private var lastRevision = -1
  @ObservationIgnored private var lastFonts = Date.distantPast
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var pollWait: Task<Void, Never>?
  @ObservationIgnored private var pollEpoch = 0
  @ObservationIgnored var pollCadence = InspectorPollCadence()
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var fontTask: Task<Void, Never>?
  @ObservationIgnored private var cachedPageFonts: [String] = []
  @ObservationIgnored private var lastPageFontScan = Date.distantPast

  init(target: SiteControlTarget, engine: BrowserEngine?) {
    self.target = target
    self.engine = engine
    connection = engine.map(InspectorConnection.init)
  }

  init(target: SiteControlTarget, privateSession: PrivatePageSession) {
    self.target = target
    connection = InspectorConnection(session: privateSession)
  }

  func open() {
    guard !isOpen else { return }
    if supportsPageTools { _ = engine?.developerModel(for: target) }
    generation += 1
    mode = .picking
    selection = nil
    installed = false
    lastRevision = -1
    failure = nil
    pollEpoch = 0
    pollCadence = InspectorPollCadence()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let pause = await self?.takePollPause() else { return }
        switch pause {
        case .stop:
          return
        case .immediately:
          continue
        case .sleep(let wait):
          await wait.value
          if self?.pollWait == wait { self?.pollWait = nil }
        }
      }
    }
  }

  /// One read, then the wait that follows. The model stays retained only for this call.
  private func takePollPause() async -> PollPause {
    guard isOpen else { return .stop }
    let epoch = pollEpoch
    let read = await refresh()
    guard isOpen, !Task.isCancelled else { return .stop }
    if pollEpoch != epoch {
      pollCadence.wake()
      return .immediately
    }
    pollCadence.note(read)
    pollCadence.picking = mode == .picking && panelMode != .page
    pollCadence.selectionLocked = mode == .locked
    pollCadence.pagePanel = panelMode == .page
    let delay = pollCadence.delay
    let wait = Task<Void, Never> { try? await Task.sleep(for: delay) }
    pollWait = wait
    if pollEpoch != epoch {
      wait.cancel()
      pollCadence.wake()
      return .immediately
    }
    return .sleep(wait)
  }

  private enum PollPause {
    case stop
    case immediately
    case sleep(Task<Void, Never>)
  }

  /// Cancel the in-flight wait so the next read happens now.
  private func wakePoll() {
    pollEpoch += 1
    pollCadence.wake()
    pollWait?.cancel()
  }

  private func endPoll() {
    pollWait?.cancel()
    pollWait = nil
    pollTask?.cancel()
    pollTask = nil
  }

  /// Hide Inspector immediately. Page commands still run until `close()`.
  func stopPresenting() {
    presentation.dismiss()
    mode = .closed
    endPoll()
    fontTask?.cancel()
    fontTask = nil
  }

  func close() {
    presentation.dismiss()
    aiCopy.cancel()
    sourceActions.cancel()
    generation += 1
    endPoll()
    fontTask?.cancel()
    fontTask = nil
    mode = .closed
    pageTools?.stop()
    pageTools = nil
    panelMode = .element
    styles.reset()
    details.reset()
    layout.reset()
    selection = nil
    installed = false
    connection?.end(target)
    let revision = generation
    // Closing can remove the last UI owner. Keep cleanup alive until the page
    // shield and native overlays are removed, while protecting a reopened model.
    Task { [self] in
      guard self.generation == revision, !self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.stop(); true")
      await self.styles.clearOverlay(generation: revision)
    }
  }

  func documentChanged(url: URL, committed: Bool = false) {
    let next = SiteControlTarget(tabID: target.tabID, profileID: target.profileID, url: url)
    if next != target || committed {
      presentation.dismiss()
      aiCopy.cancel()
      sourceActions.cancel()
      generation += 1
      styles.reset()
      details.reset()
      layout.reset()
      pageTools?.documentChanged()
      target = next
      installed = false
      fontTask?.cancel()
      fontTask = nil
      cachedPageFonts = []
      lastPageFontScan = .distantPast
      lastRevision = -1
      selection = nil
      if isOpen {
        mode = .picking
        wakePoll()
      }
      connection?.end(target)
    }
  }

  func setPanelMode(_ value: PanelMode) {
    guard isOpen else { return }
    guard value == .element || supportsPageTools else { return }
    wakePoll()
    presentation.copyMenuOpen = false
    panelMode = value
    if value == .page, pageTools == nil, let engine {
      pageTools = InspectorPageToolsModel(
        inspector: self, developer: engine.developerModel(for: target))
    }
    if value == .page { pageTools?.start() }
    let generation = generation
    Task { [weak self] in
      guard let self, self.isOpen, self.generation == generation else { return }
      _ = try? await self.evaluate(
        "globalThis.__shaarInspectorV2?.suspend(\(self.panelMode == .page)); true")
      if self.panelMode == .page { await self.styles.clearOverlay(generation: generation) }
    }
  }

  @discardableResult
  func pick() -> Task<Void, Never>? {
    if panelMode != .element { setPanelMode(.element) }
    guard isOpen else {
      open()
      return nil
    }
    wakePoll()
    let revision = generation
    return Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.pick(); true")
      guard self.generation == revision, self.isOpen else { return }
      self.mode = .picking
      await self.refresh()
    }
  }

  func selectAncestor(_ id: Int) {
    guard isOpen, selection?.ancestors.contains(where: { $0.id == id }) == true else { return }
    wakePoll()
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.choose(\(id)); true")
      guard self.generation == revision, self.isOpen else { return }
      await self.refresh()
    }
  }

  func navigate(_ direction: String) {
    guard isOpen, panelMode == .element, ["up", "down", "left", "right"].contains(direction) else {
      return
    }
    wakePoll()
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.navigate('\(direction)'); true")
      guard self.generation == revision, self.isOpen else { return }
      await self.refresh()
    }
  }

  func copy(_ value: String) {
    copy(value, label: "value")
  }

  func copy(_ value: String, label: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    if pasteboard.setString(value, forType: .string) { presentation.copied(label) }
  }

  func toggleLock() {
    if mode == .locked { pick() } else if let selection { selectAncestor(selection.id) }
  }

  func highlightEdge(_ region: String, _ index: Int, active: Bool) {
    guard isOpen, panelMode == .element, let selection,
      ["margin", "border", "padding"].contains(region), (0...3).contains(index)
    else { return }
    let generation = generation
    Task { [weak self] in
      guard let self, self.isOpen, self.generation == generation, self.selection?.id == selection.id
      else { return }
      _ = try? await self.evaluate(
        "globalThis.__shaarInspectorV2?.highlightEdge(\(active ? "'" + region + "'" : "null"),\(index)); true"
      )
    }
  }

  /// Changed when the selection moved. Unavailable when the page could not be read.
  /// Busy when another read is already in flight. Unchanged when the revision held.
  @discardableResult
  func refresh() async -> InspectorPollRead {
    if refreshing { return .busy }
    guard isOpen, let connection, connection.isReady(for: target) else {
      return isOpen ? .unavailable : .unchanged
    }
    refreshing = true
    defer { refreshing = false }
    let revision = generation
    do {
      if !installed {
        guard
          connection.begin(target)
        else { throw InspectorFailure(InspectorL10n.string("This page is no longer available.")) }
        _ = try await evaluate(InspectorPageScript.install)
        _ = try await evaluate(InspectorStyleScript.install)
        _ = try await evaluate(InspectorDetailsScript.install)
        _ = try await call("Page.enable")
        _ = try await call("DOM.enable")
        _ = try await call("DOM.getDocument", params: ["depth": 0])
        _ = try await call("CSS.enable")
        guard revision == generation, isOpen else { return .unchanged }
        installed = true
        if panelMode == .page {
          _ = try await evaluate("globalThis.__shaarInspectorV2.suspend(true)")
        }
        return .changed
      }
      if panelMode == .page { return .unchanged }
      guard
        let state = try await evaluate("globalThis.__shaarInspectorV2?.read()") as? [String: Any],
        revision == generation, isOpen
      else { return .unavailable }
      if state["closed"] as? Bool == true {
        close()
        return .changed
      }
      guard let value = state["selection"] as? [String: Any] else {
        let hadSelection = selection != nil
        selection = nil
        mode = .picking
        return hadSelection ? .changed : .unchanged
      }
      let valueRevision = value["revision"] as? Int ?? -1
      let revisionChanged = valueRevision != lastRevision
      guard revisionChanged || Date().timeIntervalSince(lastFonts) > 2 else { return .unchanged }
      let data = try JSONSerialization.data(withJSONObject: value)
      guard data.count <= 1_048_576 else {
        throw InspectorFailure(InspectorL10n.string("Element data exceeds the supported size."))
      }
      var next = try JSONDecoder().decode(InspectorSelection.self, from: data)
      guard next.valid else {
        throw InspectorFailure(InspectorL10n.string("Element data could not be displayed."))
      }
      readingFonts = true
      defer { if revision == generation { readingFonts = false } }
      let objectGroup = "shaar-inspector-selection-\(UUID().uuidString)"
      let destination = target
      defer { releaseGroup(objectGroup, target: destination) }
      let object = try await call(
        "Runtime.evaluate",
        params: [
          "expression": "globalThis.__shaarInspectorV2.element()", "objectGroup": objectGroup,
        ])
      if let objectID = (object["result"] as? [String: Any])?["objectId"] as? String {
        if let nodeID = try? await call("DOM.requestNode", params: ["objectId": objectID])["nodeId"]
          as? Int
        {
          if let fonts = try? await self.fonts(for: nodeID) {
            next.renderedFonts = fonts
            next.fontsAvailable = true
          }
        }
        if let model = try? await call("DOM.getBoxModel", params: ["objectId": objectID])["model"]
          as? [String: Any],
          let quads = try? JSONSerialization.data(withJSONObject: model),
          let encoded = String(data: quads, encoding: .utf8)
        {
          _ = try? await evaluate(
            "globalThis.__shaarInspectorV2?.quads(\(next.id),\(next.revision),\(encoded)); true")
        }
      }
      let liveRevision = try await evaluate("globalThis.__shaarInspectorV2?.revision()") as? Int
      guard revision == generation, isOpen, liveRevision == valueRevision else { return .changed }
      next.pageFonts = cachedPageFonts
      try receive(next)
      if fontTask == nil && Date().timeIntervalSince(lastPageFontScan) > 15 {
        fontTask = Task { [weak self] in await self?.scanPageFonts() }
      }
      return revisionChanged ? .changed : .unchanged
    } catch {
      if revision == generation, !Task.isCancelled {
        failure = Self.captureFailureMessage(for: error)
      }
      return .unavailable
    }
  }

  static func captureFailureMessage(
    for error: Error, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    if error is InspectorFailure || error is DeveloperModeFailure {
      return InspectorL10n.display(error.localizedDescription)
    }
    return BrowserLocalization.string(
      "The page could not complete the Inspector request.", table: "Inspector", language: language)
  }

  /// Apply validated renderer data independently of protocol transport and native rendering.
  func receive(_ next: InspectorSelection) throws {
    guard isOpen, next.valid else {
      throw InspectorFailure(InspectorL10n.string("Element data could not be displayed."))
    }
    selection = next
    lastRevision = next.revision
    lastFonts = Date()
    mode = next.locked ? .locked : .picking
    failure = nil
    layout.selectionLocked(next.locked ? next.id : nil)
  }

  private func fonts(for nodeID: Int) async throws -> [String] {
    let result = try await call("CSS.getPlatformFontsForNode", params: ["nodeId": nodeID])
    guard let fonts = result["fonts"] as? [[String: Any]] else {
      throw InspectorFailure(InspectorL10n.string("Chromium did not return rendered font data."))
    }
    return Array(
      Set(
        fonts.compactMap { row in
          (row["familyName"] as? String).map { String($0.prefix(160)) }
        })
    ).sorted().prefix(80).map { $0 }
  }

  private func scanPageFonts() async {
    let revision = generation
    defer { if revision == generation { fontTask = nil } }
    do {
      let objectGroup = "shaar-inspector-fonts-\(UUID().uuidString)"
      let destination = target
      defer { releaseGroup(objectGroup, target: destination) }
      let object = try await call(
        "Runtime.evaluate",
        params: [
          "expression": "globalThis.__shaarInspectorV2.fontElements()",
          "objectGroup": objectGroup,
        ])
      guard let objectID = (object["result"] as? [String: Any])?["objectId"] as? String else {
        return
      }
      let properties = try await call(
        "Runtime.getProperties", params: ["objectId": objectID, "ownProperties": true])
      let rows = properties["result"] as? [[String: Any]] ?? []
      let objects = rows.compactMap { row -> String? in
        guard let name = row["name"] as? String, Int(name) != nil else { return nil }
        return (row["value"] as? [String: Any])?["objectId"] as? String
      }.prefix(160)
      var names = Set<String>()
      for object in objects {
        guard !Task.isCancelled, revision == generation, isOpen else { return }
        if let nodeID = try? await call("DOM.requestNode", params: ["objectId": object])["nodeId"]
          as? Int,
          let rendered = try? await fonts(for: nodeID)
        {
          names.formUnion(rendered)
        }
      }
      let truncated =
        try await evaluate("globalThis.__shaarInspectorV2.fontScanTruncated()") as? Bool ?? false
      guard revision == generation, isOpen, !Task.isCancelled else { return }
      cachedPageFonts = names.sorted()
      pageFontsTruncated = truncated
      lastPageFontScan = Date()
      if var current = selection {
        current.pageFonts = cachedPageFonts
        selection = current
      }
    } catch {
      if revision == generation { lastPageFontScan = Date() }
    }
  }

  func releaseGroup(_ group: String, target: SiteControlTarget) {
    guard let connection else { return }
    Task {
      // Unique groups let stale cleanup release its own objects without touching a new selection.
      _ = try? await connection.call(
        "Runtime.releaseObjectGroup", params: ["objectGroup": group],
        target: target)
    }
  }

  func withSelectedNode<T>(_ operation: (Int) async throws -> T) async throws -> T {
    guard let selection, selection.locked else {
      throw InspectorFailure(InspectorL10n.string("Lock an element first."))
    }
    let identity = selection.id
    let revision = generation
    let group = "shaar-inspector-node-\(UUID().uuidString)"
    let destination = target
    defer { releaseGroup(group, target: destination) }
    let result = try await call(
      "Runtime.evaluate",
      params: [
        "expression": "globalThis.__shaarInspectorV2.element()", "objectGroup": group,
      ])
    guard let objectID = (result["result"] as? [String: Any])?["objectId"] as? String,
      let nodeID = try await call("DOM.requestNode", params: ["objectId": objectID])["nodeId"]
        as? Int,
      generation == revision, self.selection?.id == identity, isOpen
    else { throw CancellationError() }
    let value = try await operation(nodeID)
    guard generation == revision, self.selection?.id == identity, isOpen else {
      throw CancellationError()
    }
    return value
  }

  func selectDOMNode(_ id: Int) async throws {
    guard try await selectResolvedNode(id) else { return }
    await refresh()
  }

  /// CSS and XPath from the Inspector page script for a CDP node, when the page can select it.
  func pathsForDOMNode(_ id: Int) async -> (css: String, xpath: String)? {
    guard isOpen, id > 0 else { return nil }
    if !installed { await refresh() }
    guard installed, isOpen else { return nil }
    let revision = generation
    do {
      guard try await selectResolvedNode(id), generation == revision else { return nil }
      await refreshWhenIdle()
    } catch {
      return nil
    }
    guard generation == revision, isOpen, let selection else { return nil }
    if selection.css.isEmpty, selection.xpath.isEmpty { return nil }
    return (selection.css, selection.xpath)
  }

  private func selectResolvedNode(_ id: Int) async throws -> Bool {
    guard id > 0 else { return false }
    let resolved = try await call("DOM.resolveNode", params: ["nodeId": id])
    guard let objectID = (resolved["object"] as? [String: Any])?["objectId"] as? String else {
      return false
    }
    let invoked = try await call(
      "Runtime.callFunctionOn",
      params: [
        "objectId": objectID,
        "functionDeclaration":
          "function() { return window.top.__shaarInspectorV2?.select(this) === true; }",
        "returnByValue": true,
      ])
    return ((invoked["result"] as? [String: Any])?["value"] as? Bool) == true
  }

  private func refreshWhenIdle() async {
    guard await Self.waitForRefreshToBecomeIdle(isRefreshing: { self.refreshing }) else { return }
    await refresh()
  }

  static func waitForRefreshToBecomeIdle(isRefreshing: () -> Bool) async -> Bool {
    for _ in 0..<20 {
      guard !Task.isCancelled else { return false }
      guard isRefreshing() else { return true }
      do {
        try await Task.sleep(for: .milliseconds(20))
      } catch {
        return false
      }
    }
    return !Task.isCancelled
  }

  func evaluate(_ expression: String) async throws -> Any? {
    let result = try await call(
      "Runtime.evaluate",
      params: ["expression": expression, "returnByValue": true, "awaitPromise": true])
    if result["exceptionDetails"] != nil {
      throw InspectorFailure(
        InspectorL10n.string("The page could not complete the Inspector request."))
    }
    return (result["result"] as? [String: Any])?["value"]
  }

  func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    guard let connection
    else {
      throw InspectorFailure(InspectorL10n.string("This Inspector target is no longer available."))
    }
    let destination = target
    let revision = generation
    let result = try await connection.call(method, params: params, target: destination)
    guard destination == target, revision == generation else { throw CancellationError() }
    return result
  }

  isolated deinit {
    pollWait?.cancel()
    pollTask?.cancel()
    fontTask?.cancel()
  }
}

/// Decides how soon Inspector reads the page again.
/// Picking an element stays at 150 ms, including when a read misses the page,
/// so a click is read on the next pass. The Page panel and a locked selection
/// that stays still wait one second after four unchanged reads. Four misses
/// also wait one second, except while an element is being picked.
/// Layout, styles, and details refresh on their own 500–700 ms loops, so this
/// one-second pause does not delay those panels.
struct InspectorPollCadence: Equatable {
  static let fastInterval: Duration = .milliseconds(150)
  static let idleInterval: Duration = .seconds(1)
  private(set) var unchangedReads = 0
  private(set) var unavailableReads = 0
  var selectionLocked = false
  var pagePanel = false
  var picking = false

  mutating func note(_ read: InspectorPollRead) {
    switch read {
    case .changed:
      unchangedReads = 0
      unavailableReads = 0
    case .unchanged:
      unchangedReads += 1
      unavailableReads = 0
    case .unavailable:
      unchangedReads += 1
      unavailableReads += 1
    case .busy:
      break
    }
  }

  mutating func wake() {
    unchangedReads = 0
    unavailableReads = 0
  }

  var delay: Duration {
    if !picking && unavailableReads >= 4 { return Self.idleInterval }
    if (selectionLocked || pagePanel) && unchangedReads >= 4 { return Self.idleInterval }
    return Self.fastInterval
  }
}

enum InspectorPollRead: Equatable {
  case changed
  case unchanged
  case unavailable
  case busy
}

struct InspectorFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

extension BrowserEngine {
  func toggleInspector(for target: SiteControlTarget? = nil) {
    guard let current = siteControlTarget, target == nil || target == current else { return }
    let model = inspectors[current.tabID] ?? InspectorModel(target: current, engine: self)
    inspectors[current.tabID] = model
    if model.isOpen { model.close() } else { model.open() }
  }
}
