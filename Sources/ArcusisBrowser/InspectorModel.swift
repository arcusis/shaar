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
    case styles = "CSS"
    case component = "Component"
    case accessibility = "A11y"
    case assets = "Assets"
  }
  enum PanelMode: String, CaseIterable {
    case element = "Element"
    case page = "Page"
  }
  private(set) var panelMode = PanelMode.element
  private(set) var pageTools: InspectorPageToolsModel?
  var tab = Tab.design
  @ObservationIgnored lazy var styles = InspectorStylesModel(inspector: self)
  @ObservationIgnored lazy var details = InspectorDetailsModel(inspector: self)
  var documentGeneration: Int { generation }
  var isOpen: Bool { mode != .closed }
  @ObservationIgnored weak var engine: BrowserEngine?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var installed = false
  @ObservationIgnored private var lastRevision = -1
  @ObservationIgnored private var lastFonts = Date.distantPast
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var fontTask: Task<Void, Never>?
  @ObservationIgnored private var cachedPageFonts: [String] = []
  @ObservationIgnored private var lastPageFontScan = Date.distantPast

  init(target: SiteControlTarget, engine: BrowserEngine?) {
    self.target = target
    self.engine = engine
  }

  func open() {
    guard !isOpen else { return }
    generation += 1
    mode = .picking
    selection = nil
    installed = false
    lastRevision = -1
    failure = nil
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        if let self, self.isOpen { await self.refresh() } else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      }
    }
  }

  func close() {
    generation += 1
    pollTask?.cancel()
    pollTask = nil
    fontTask?.cancel()
    fontTask = nil
    mode = .closed
    pageTools?.stop()
    pageTools = nil
    panelMode = .element
    styles.reset()
    details.reset()
    selection = nil
    installed = false
    engine?.runtime.endInspector(forTabID: target.tabID.uuidString)
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, !self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.stop(); true")
      await self.styles.clearOverlay(generation: revision)
    }
  }

  func documentChanged(url: URL, committed: Bool = false) {
    let next = SiteControlTarget(tabID: target.tabID, profileID: target.profileID, url: url)
    if next != target || committed {
      generation += 1
      styles.reset()
      details.reset()
      pageTools?.documentChanged()
      target = next
      installed = false
      fontTask?.cancel()
      fontTask = nil
      cachedPageFonts = []
      lastPageFontScan = .distantPast
      lastRevision = -1
      selection = nil
      if isOpen { mode = .picking }
      engine?.runtime.endInspector(forTabID: target.tabID.uuidString)
    }
  }

  func setPanelMode(_ value: PanelMode) {
    guard isOpen else { return }
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

  func pick() {
    if panelMode != .element { setPanelMode(.element) }
    guard isOpen else {
      open()
      return
    }
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.pick(); true")
      guard self.generation == revision, self.isOpen else { return }
      self.mode = .picking
    }
  }

  func selectAncestor(_ id: Int) {
    guard isOpen, selection?.ancestors.contains(where: { $0.id == id }) == true else { return }
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.choose(\(id)); true")
    }
  }

  func navigate(_ direction: String) {
    guard isOpen, panelMode == .element, ["up", "down", "left", "right"].contains(direction) else {
      return
    }
    let revision = generation
    Task { [weak self] in
      guard let self, self.generation == revision, self.isOpen else { return }
      _ = try? await self.evaluate("globalThis.__shaarInspectorV2?.navigate('\(direction)'); true")
    }
  }

  func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func refresh() async {
    guard !refreshing, isOpen, let engine, !engine.isClosed,
      engine.pages[target.tabID]?.loading == false
    else { return }
    refreshing = true
    defer { refreshing = false }
    let revision = generation
    do {
      if !installed {
        guard
          engine.runtime.beginInspector(
            forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
            windowID: engine.windowID)
        else { throw InspectorFailure("This page is no longer available.") }
        _ = try await evaluate(InspectorPageScript.install)
        _ = try await evaluate(InspectorStyleScript.install)
        _ = try await evaluate(InspectorDetailsScript.install)
        _ = try await call("Page.enable")
        _ = try await call("DOM.enable")
        _ = try await call("DOM.getDocument", params: ["depth": 0])
        _ = try await call("CSS.enable")
        guard revision == generation, isOpen else { return }
        installed = true
        if panelMode == .page {
          _ = try await evaluate("globalThis.__shaarInspectorV2.suspend(true)")
        }
      }
      if panelMode == .page { return }
      guard
        let state = try await evaluate("globalThis.__shaarInspectorV2?.read()") as? [String: Any],
        revision == generation, isOpen
      else { return }
      if state["closed"] as? Bool == true {
        close()
        return
      }
      guard let value = state["selection"] as? [String: Any] else {
        selection = nil
        mode = .picking
        return
      }
      let valueRevision = value["revision"] as? Int ?? -1
      guard valueRevision != lastRevision || Date().timeIntervalSince(lastFonts) > 2 else { return }
      let data = try JSONSerialization.data(withJSONObject: value)
      guard data.count <= 1_048_576 else {
        throw InspectorFailure("Element data exceeds the supported size.")
      }
      var next = try JSONDecoder().decode(InspectorSelection.self, from: data)
      guard next.valid else { throw InspectorFailure("Element data could not be displayed.") }
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
      guard revision == generation, isOpen, liveRevision == valueRevision else { return }
      next.pageFonts = cachedPageFonts
      try receive(next)
      if fontTask == nil && Date().timeIntervalSince(lastPageFontScan) > 15 {
        fontTask = Task { [weak self] in await self?.scanPageFonts() }
      }
    } catch {
      if revision == generation, !Task.isCancelled { failure = error.localizedDescription }
    }
  }

  /// Apply validated renderer data independently of protocol transport and native rendering.
  func receive(_ next: InspectorSelection) throws {
    guard isOpen, next.valid else { throw InspectorFailure("Element data could not be displayed.") }
    selection = next
    lastRevision = next.revision
    lastFonts = Date()
    mode = next.locked ? .locked : .picking
    failure = nil
  }

  private func fonts(for nodeID: Int) async throws -> [String] {
    let result = try await call("CSS.getPlatformFontsForNode", params: ["nodeId": nodeID])
    guard let fonts = result["fonts"] as? [[String: Any]] else {
      throw InspectorFailure("Chromium did not return rendered font data.")
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
    guard let engine else { return }
    let window = engine.windowID
    Task { [weak runtime = engine.runtime] in
      // Unique groups let stale cleanup release its own objects without touching a new selection.
      _ = try? await runtime?.inspectorCall(
        "Runtime.releaseObjectGroup", params: ["objectGroup": group],
        tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: window)
    }
  }

  func withSelectedNode<T>(_ operation: (Int) async throws -> T) async throws -> T {
    guard let selection, selection.locked else { throw InspectorFailure("Lock an element first.") }
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

  func evaluate(_ expression: String) async throws -> Any? {
    let result = try await call(
      "Runtime.evaluate",
      params: ["expression": expression, "returnByValue": true, "awaitPromise": true])
    if result["exceptionDetails"] != nil {
      throw InspectorFailure("The page could not complete the Inspector request.")
    }
    return (result["result"] as? [String: Any])?["value"]
  }

  func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    guard let engine, !engine.isClosed,
      engine.store?.session.profileID(forTabID: target.tabID) == target.profileID,
      engine.runtime.windowID(forTabID: target.tabID.uuidString) == engine.windowID
    else { throw InspectorFailure("This Inspector target is no longer available.") }
    let destination = target
    let revision = generation
    let result = try await engine.runtime.inspectorCall(
      method, params: params, tabID: destination.tabID.uuidString,
      profileID: destination.profileID.uuidString, windowID: engine.windowID)
    guard destination == target, revision == generation else { throw CancellationError() }
    return result
  }

  isolated deinit {
    pollTask?.cancel()
    fontTask?.cancel()
  }
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
