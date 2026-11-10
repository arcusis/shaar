// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

@MainActor protocol ShaarA11yCalling: AnyObject {
  func evaluate(_ expression: String) async throws -> Any?
  func call(_ method: String, params: [String: Any]) async throws -> [String: Any]
}

extension InspectorModel: ShaarA11yCalling {}

struct ShaarA11yBadge: Equatable {
  enum Kind: Equatable {
    case focus(Int)
    case contrast(String)
  }

  var kind: Kind
  var marker: String
  var snippet: String
  var x: Double
  var y: Double
}

struct ShaarA11yOverlayRow: Identifiable, Equatable {
  var id: String
  var title: String
  var detail: String
}

struct ShaarA11yOverlayTrace: Equatable {
  var boxModel = false
  var backgroundColors = false
  var partialAXTree = false
  var computedStyle = false
}

@MainActor private final class ShaarA11yTraceBox {
  var boxModel = false
  var backgroundColors = false
  var partialAXTree = false
  var computedStyle = false

  func snapshot() -> ShaarA11yOverlayTrace {
    ShaarA11yOverlayTrace(
      boxModel: boxModel, backgroundColors: backgroundColors, partialAXTree: partialAXTree,
      computedStyle: computedStyle)
  }
}

@MainActor @Observable
final class ShaarA11yOverlayModel {
  private(set) var enabled = false
  private(set) var summary = ""
  private(set) var failure: String?
  private(set) var rows: [ShaarA11yOverlayRow] = []
  private(set) var badges: [ShaarA11yBadge] = []
  private(set) var trace = ShaarA11yOverlayTrace()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  func setEnabled(_ on: Bool, caller: (any ShaarA11yCalling)?) {
    guard on, let caller else {
      stop(on ? nil : caller)
      if on { failure = "This page is not ready for the overlay." }
      return
    }
    generation += 1
    let token = generation
    enabled = true
    failure = nil
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      await self.refresh(caller, token: token)
      while !Task.isCancelled, token == self.generation, self.enabled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, token == self.generation, self.enabled else { return }
        await self.refresh(caller, token: token)
      }
    }
  }

  func stop(_ caller: (any ShaarA11yCalling)?) {
    generation += 1
    enabled = false
    refreshTask?.cancel()
    refreshTask = nil
    summary = ""
    failure = nil
    rows = []
    badges = []
    trace = ShaarA11yOverlayTrace()
    guard let caller else { return }
    let expression = ShaarA11yOverlayScript.clear
    refreshTask = Task {
      _ = try? await caller.evaluate(expression)
    }
  }

  func refresh(_ caller: any ShaarA11yCalling, token: Int? = nil) async {
    let token = token ?? generation
    do {
      _ = try await caller.call("DOM.enable", params: [:])
      _ = try await caller.call("CSS.enable", params: [:])
      guard token == generation, enabled else { return }
      guard let inventory = ShaarA11yInventoryDecoder.decode(
        try await caller.evaluate(ShaarA11yOverlayScript.collect))
      else {
        failure = "The page did not list its tab stops."
        return
      }
      guard token == generation, enabled else { return }
      let index = try await markers(in: caller, inventory: inventory)
      guard token == generation, enabled else { return }
      let nextTrace = ShaarA11yTraceBox()
      let focus = await focusBadges(
        ShaarFocusOrder.ordered(inventory.stops), index: index, inventory: inventory,
        caller: caller, trace: nextTrace)
      let scored = await contrastBadges(
        inventory.texts, index: index, inventory: inventory, caller: caller, trace: nextTrace)
      guard token == generation, enabled else { return }
      let painted = focus + scored.badges
      guard let expression = ShaarA11yOverlayScript.paint(payload(painted)) else {
        failure = "The overlay could not be drawn."
        return
      }
      _ = try await caller.evaluate(expression)
      guard token == generation, enabled else {
        _ = try? await caller.evaluate(ShaarA11yOverlayScript.clear)
        return
      }
      badges = painted
      rows = displayRows(focus: focus, contrast: scored.badges)
      summary = summaryText(
        stops: focus.count, failures: scored.badges.count, limited: scored.limited,
        truncated: inventory.truncated)
      failure = nil
      trace = nextTrace.snapshot()
    } catch is CancellationError {
      return
    } catch {
      guard token == generation else { return }
      failure = String(error.localizedDescription.prefix(180))
    }
  }

  private func markers(in caller: any ShaarA11yCalling, inventory: ShaarA11yInventory) async throws
    -> ShaarA11yDOMIndex
  {
    let document = try await caller.call(
      "DOM.getDocument", params: ["depth": -1, "pierce": true])
    var index = ShaarA11yDOMIndex.walk(ShaarA11yJSON.object(document["root"]))
    let needsSearch = index.focus.isEmpty && index.contrast.isEmpty
      && (!inventory.stops.isEmpty || !inventory.texts.isEmpty)
    if needsSearch { index = try await searchMarkers(in: caller) }
    return index
  }

  private func searchMarkers(in caller: any ShaarA11yCalling) async throws -> ShaarA11yDOMIndex {
    let focus = try await search("[data-shaar-focus]", caller: caller)
    let contrast = try await search("[data-shaar-contrast]", caller: caller)
    return ShaarA11yDOMIndex(
      focus: focus.focus.merging(contrast.focus) { current, _ in current },
      contrast: focus.contrast.merging(contrast.contrast) { current, _ in current })
  }

  private func search(_ query: String, caller: any ShaarA11yCalling) async throws -> ShaarA11yDOMIndex
  {
    let found = try await caller.call("DOM.performSearch", params: ["query": query])
    let searchID = found["searchId"] as? String ?? ""
    let count = ShaarA11yJSON.int(found["resultCount"]) ?? 0
    guard count > 0, !searchID.isEmpty else { return ShaarA11yDOMIndex.empty() }
    let page = try await caller.call(
      "DOM.getSearchResults",
      params: ["searchId": searchID, "fromIndex": 0, "toIndex": min(count, 80)])
    let nodeIDs = (ShaarA11yJSON.array(page["nodeIds"]) ?? []).compactMap(ShaarA11yJSON.int)
    var index = ShaarA11yDOMIndex.empty()
    for nodeID in nodeIDs {
      let described = try await caller.call("DOM.describeNode", params: ["nodeId": nodeID])
      guard let node = ShaarA11yJSON.object(described["node"]) else { continue }
      ShaarA11yDOMIndex.read(attributes: node, nodeID: nodeID, into: &index)
    }
    _ = try? await caller.call("DOM.discardSearchResults", params: ["searchId": searchID])
    return index
  }

  private func focusBadges(
    _ stops: [ShaarFocusStop], index: ShaarA11yDOMIndex, inventory: ShaarA11yInventory,
    caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> [ShaarA11yBadge] {
    var badges: [ShaarA11yBadge] = []
    for (offset, stop) in stops.enumerated() {
      let nodeID = index.focus[stop.id]
      let origin = await origin(
        nodeID: nodeID, fallback: stop.origin, inventory: inventory, caller: caller, trace: trace)
      let name = await accessibleName(
        nodeID: nodeID, fallback: stop.name, caller: caller, trace: trace)
      badges.append(
        ShaarA11yBadge(
          kind: .focus(offset + 1), marker: String(stop.id), snippet: name,
          x: origin.x, y: origin.y))
    }
    return badges
  }

  private func contrastBadges(
    _ texts: [ShaarA11yText], index: ShaarA11yDOMIndex, inventory: ShaarA11yInventory,
    caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> (badges: [ShaarA11yBadge], limited: Int) {
    var badges: [ShaarA11yBadge] = []
    var limited = 0
    for text in texts {
      guard let nodeID = index.contrast[text.id] else {
        limited += 1
        continue
      }
      let style = await computedStyle(nodeID: nodeID, caller: caller, trace: trace)
      let colors = await backgroundColors(nodeID: nodeID, caller: caller, trace: trace)
      guard let decision = ShaarA11yContrast.decide(style: style, colors: colors) else {
        limited += 1
        continue
      }
      guard decision.fails else { continue }
      let origin = await origin(
        nodeID: nodeID, fallback: text.origin, inventory: inventory, caller: caller, trace: trace)
      badges.append(
        ShaarA11yBadge(
          kind: .contrast(ShaarA11yContrast.ratioText(decision.ratio)),
          marker: String(text.id), snippet: text.snippet, x: origin.x, y: origin.y))
    }
    return (badges, limited)
  }

  private func origin(
    nodeID: Int?, fallback: ShaarA11yPoint, inventory: ShaarA11yInventory,
    caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> ShaarA11yPoint {
    guard let nodeID else { return fallback }
    do {
      let model = try await caller.call("DOM.getBoxModel", params: ["nodeId": nodeID])
      trace.boxModel = true
      return ShaarA11yBox.viewportOrigin(model, scrollX: inventory.scrollX, scrollY: inventory.scrollY)
        ?? fallback
    } catch {
      return fallback
    }
  }

  private func accessibleName(
    nodeID: Int?, fallback: String, caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> String {
    guard let nodeID else { return fallback }
    do {
      let tree = try await caller.call(
        "Accessibility.getPartialAXTree",
        params: ["nodeId": nodeID, "fetchRelatives": false])
      trace.partialAXTree = true
      return ShaarA11yAXName.read(tree) ?? fallback
    } catch {
      return fallback
    }
  }

  private func computedStyle(
    nodeID: Int, caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> [String: Any]? {
    do {
      let style = try await caller.call(
        "CSS.getComputedStyleForNode", params: ["nodeId": nodeID])
      trace.computedStyle = true
      return style
    } catch {
      return nil
    }
  }

  private func backgroundColors(
    nodeID: Int, caller: any ShaarA11yCalling, trace: ShaarA11yTraceBox
  ) async -> [String: Any]? {
    do {
      let colors = try await caller.call("CSS.getBackgroundColors", params: ["nodeId": nodeID])
      trace.backgroundColors = true
      return colors
    } catch {
      return nil
    }
  }

  private func payload(_ badges: [ShaarA11yBadge]) -> [[String: Any]] {
    badges.map { badge in
      let kind: String
      let label: String
      switch badge.kind {
      case .focus(let number):
        kind = "focus"
        label = String(number)
      case .contrast(let ratio):
        kind = "contrast"
        label = ratio
      }
      return [
        "kind": kind,
        "label": label,
        "marker": badge.marker,
        "group": kind,
        "snippet": badge.snippet,
        "x": badge.x,
        "y": badge.y,
      ]
    }
  }

  private func displayRows(focus: [ShaarA11yBadge], contrast: [ShaarA11yBadge])
    -> [ShaarA11yOverlayRow]
  {
    var rows: [ShaarA11yOverlayRow] = []
    for badge in focus.prefix(8) {
      guard case .focus(let number) = badge.kind else { continue }
      rows.append(
        ShaarA11yOverlayRow(id: "focus-\(badge.marker)", title: String(number), detail: badge.snippet))
    }
    for badge in contrast.prefix(8) {
      guard case .contrast(let ratio) = badge.kind else { continue }
      rows.append(
        ShaarA11yOverlayRow(id: "contrast-\(badge.marker)", title: ratio, detail: badge.snippet))
    }
    return rows
  }

  private func summaryText(stops: Int, failures: Int, limited: Int, truncated: Bool) -> String {
    var parts = [
      counted(stops, singular: "tab stop", plural: "tab stops"),
      counted(failures, singular: "contrast failure", plural: "contrast failures"),
    ]
    if limited > 0 { parts.append("\(limited) not scored") }
    if truncated { parts.append("list limited") }
    return parts.joined(separator: " · ")
  }

  private func counted(_ count: Int, singular: String, plural: String) -> String {
    if count == 1 { return "1 \(singular)" }
    return "\(count) \(plural)"
  }
}
