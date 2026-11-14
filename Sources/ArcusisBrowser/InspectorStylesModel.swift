// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct InspectorDeclaration: Identifiable, Equatable {
  let name: String
  let value: String
  var key: String? = nil
  var disabled = false
  var id: String { key ?? name }
  var important: Bool { value.hasSuffix(" !important") }
  var plainValue: String { important ? String(value.dropLast(11)) : value }
}

enum InspectorRuleOrigin: Equatable {
  case inline
  case author
  case userAgent
}

struct InspectorRule: Identifiable {
  let id: Int
  let selector: String
  let source: String
  var declarations: [InspectorDeclaration]
  var origin: InspectorRuleOrigin = .author
  var editable = false
  var matchText = ""
  var note = ""
  var specificity = InspectorSpecificity()
  var cascadeOrder = 0
  /// Zero is the selected element. Larger values are ancestors, parent first.
  var distance = 0
}

@MainActor @Observable
final class InspectorStylesModel {
  @ObservationIgnored weak var inspector: InspectorModel?
  private(set) var rules: [InspectorRule] = []
  private(set) var computed: [InspectorDeclaration] = []
  private(set) var inactiveHints: [String: String] = [:]
  private(set) var selectedID: Int?
  private(set) var failure: String?
  private(set) var busy = false
  private(set) var overlay = false
  private(set) var undoDepth = 0
  private(set) var capturing = false
  private(set) var forcedPseudos: Set<String> = []
  var filter = ""
  @ObservationIgnored private var epoch = -1
  @ObservationIgnored private var updated = Date.distantPast
  @ObservationIgnored private var sources: [String: String] = [:]
  @ObservationIgnored private var resources: [(String, String)] = []
  @ObservationIgnored private var resourcesLoaded = false
  @ObservationIgnored private var forcedNodeID: Int?
  @ObservationIgnored private var forcing = false

  init(inspector: InspectorModel) { self.inspector = inspector }

  func reset() {
    let node = takeForcedNode()
    rules = []
    computed = []
    inactiveHints = [:]
    selectedID = nil
    overlay = false
    undoDepth = 0
    sources = [:]
    resources = []
    resourcesLoaded = false
    updated = .distantPast
    failure = nil
    guard node != nil else { return }
    Task { [weak self] in
      await self?.releaseForcedNode(node)
    }
  }

  var layout: [InspectorDeclaration] {
    let display = computed.first { $0.name == "display" }?.value ?? ""
    let common = ["display", "position", "box-sizing", "overflow-x", "overflow-y"]
    let extra =
      display.contains("flex")
      ? [
        "flex-direction", "flex-wrap", "justify-content", "align-items", "align-content", "row-gap",
        "column-gap",
      ]
      : display.contains("grid")
        ? [
          "grid-template-columns", "grid-template-rows", "grid-auto-flow", "justify-items",
          "align-items", "row-gap", "column-gap",
        ] : []
    return (common + extra).compactMap { name in computed.first { $0.name == name } }
  }

  var canOverlay: Bool {
    computed.contains {
      $0.name == "display" && ($0.value.contains("flex") || $0.value.contains("grid"))
    }
  }

  func refresh(force: Bool = false) async {
    if force {
      while busy && inspector?.isOpen == true && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }
    guard !Task.isCancelled, !busy, let inspector, inspector.isOpen,
      let selection = inspector.selection,
      selection.locked
    else { return }
    let generation = inspector.documentGeneration
    guard
      force || selectedID != selection.id || epoch != generation
        || Date().timeIntervalSince(updated) > 2
    else { return }
    busy = true
    defer { busy = false }
    do {
      if selectedID != selection.id || epoch != generation {
        await clearOverlay()
        let selectionChanged = selectedID != nil && selectedID != selection.id
        let documentChanged = epoch >= 0 && epoch != generation
        if selectionChanged || documentChanged {
          await releaseForcedNode(takeForcedNode())
        }
        rules = []
        computed = []
      }
      let (matched, values) = try await inspector.withSelectedNode { node in
        let matched = try await inspector.call(
          "CSS.getMatchedStylesForNode",
          params: ["nodeId": node, "includePseudo": true, "includeInherited": true])
        let values = try await inspector.call(
          "CSS.getComputedStyleForNode", params: ["nodeId": node])
        return (matched, values)
      }
      guard let rows = values["computedStyle"] as? [[String: Any]] else {
        throw InspectorFailure(InspectorL10n.string("Computed styles are unavailable."))
      }
      let nextComputed = rows.prefix(2048).compactMap { row -> InspectorDeclaration? in
        guard let name = row["name"] as? String, name.count <= 128,
          let value = row["value"] as? String, value.count <= 4096
        else { return nil }
        return InspectorDeclaration(name: name, value: value)
      }.sorted { $0.name < $1.name }
      var nextRules: [InspectorRule] = []
      if let inline = matched["inlineStyle"] as? [String: Any],
        !declarations(inline).isEmpty
      {
        nextRules.append(inlineRule(inline))
      }
      await appendMatches(
        (matched["matchedCSSRules"] as? [[String: Any]]) ?? [], note: "", limit: 80,
        into: &nextRules, inspector: inspector)
      for pseudo in ((matched["pseudoElements"] as? [[String: Any]]) ?? []).prefix(8) {
        let name = (pseudo["pseudoType"] as? String).map { "::\($0)" } ?? ""
        await appendMatches(
          (pseudo["matches"] as? [[String: Any]]) ?? [], note: name, limit: 4,
          into: &nextRules, inspector: inspector)
      }
      let ancestors = ((matched["inherited"] as? [[String: Any]]) ?? []).prefix(4)
      for (index, ancestor) in ancestors.enumerated() {
        let distance = index + 1
        if let inline = ancestor["inlineStyle"] as? [String: Any], !declarations(inline).isEmpty,
          nextRules.count < 120
        {
          let inherited = inlineRule(inline)
          nextRules.append(
            InspectorRule(
              id: nextRules.count, selector: inherited.selector, source: inherited.source,
              declarations: inherited.declarations, origin: .inline, editable: false,
              note: "Inherited", distance: distance))
        }
        await appendMatches(
          (ancestor["matchedCSSRules"] as? [[String: Any]]) ?? [], note: "Inherited", limit: 4,
          distance: distance, into: &nextRules, inspector: inspector)
      }
      if let muted = try? await inspector.evaluate(
        "globalThis.__shaarInspectorStyles.mutedRows()") as? [[String: String]]
      {
        nextRules = mergingMuted(muted, into: nextRules)
      }
      guard inspector.isOpen, inspector.documentGeneration == generation,
        inspector.selection?.id == selection.id
      else { return }
      let properties = Array(Set(nextRules.flatMap(\.declarations).map(\.name))).sorted()
      let inactiveHints =
        (try? await inspector.evaluate(
          InspectorInactiveCSSRules.expression(properties: properties))) as? [String: String]
        ?? [:]
      try receive(
        rules: nextRules, computed: nextComputed, inactiveHints: inactiveHints,
        selectionID: selection.id, generation: generation)
      undoDepth =
        try await inspector.evaluate("globalThis.__shaarInspectorStyles.undoDepth()") as? Int ?? 0
      failure = nil
    } catch {
      if inspector.documentGeneration == generation, !(error is CancellationError) {
        failure = Self.failureMessage(for: error)
      }
    }
  }

  /// Commit one bounded snapshot only while its original selection and document remain current.
  func receive(
    rules: [InspectorRule], computed: [InspectorDeclaration], inactiveHints: [String: String] = [:],
    selectionID: Int, generation: Int
  ) throws {
    guard let inspector, inspector.isOpen, inspector.selection?.id == selectionID,
      inspector.documentGeneration == generation
    else { throw CancellationError() }
    guard rules.count <= 120, computed.count <= 2048,
      rules.allSatisfy({
        $0.selector.count <= 2048 && $0.source.count <= 16_384 && $0.declarations.count <= 120
      }),
      (computed + rules.flatMap(\.declarations)).allSatisfy({
        $0.name.count <= 128 && $0.value.count <= 4110
      })
    else { throw InspectorFailure(InspectorL10n.string("Style data exceeds the supported size.")) }
    self.rules = rules
    self.computed = computed
    self.inactiveHints = inactiveHints
    selectedID = selectionID
    epoch = generation
    updated = Date()
  }

  private func inlineRule(_ style: [String: Any]) -> InspectorRule {
    InspectorRule(
      id: 0, selector: "element.style", source: "Inline overrides",
      declarations: declarations(style), origin: .inline, editable: true,
      matchText: String(((style["cssText"] as? String) ?? "").prefix(65_536)))
  }

  private func appendMatches(
    _ rows: [[String: Any]], note: String, limit: Int, distance: Int = 0,
    into rules: inout [InspectorRule], inspector: InspectorModel
  ) async {
    let kept = Array(rows.suffix(limit))
    let start = rows.count - kept.count
    for offset in stride(from: kept.count - 1, through: 0, by: -1) {
      let row = kept[offset]
      guard rules.count < 120, let rule = row["rule"] as? [String: Any],
        let style = rule["style"] as? [String: Any],
        let selectors = rule["selectorList"] as? [String: Any],
        let selector = selectors["text"] as? String
      else { continue }
      let sheet = rule["styleSheetId"] as? String
      let line = ((style["range"] as? [String: Any])?["startLine"] as? Int).map { $0 + 1 }
      let location: String
      if let sheet {
        location =
          await source(for: sheet, selector: selector, style: style, inspector: inspector)
          + (line.map { ":\($0)" } ?? "")
      } else {
        location =
          rule["origin"] as? String == "user-agent" ? "Browser default" : "Source unavailable"
      }
      let origin: InspectorRuleOrigin =
        rule["origin"] as? String == "user-agent" ? .userAgent : .author
      let matchText = String(((style["cssText"] as? String) ?? "").prefix(65_536))
      rules.append(
        InspectorRule(
          id: rules.count, selector: String(selector.prefix(2048)), source: location,
          declarations: declarations(style), origin: origin,
          editable: origin == .author && !matchText.isEmpty, matchText: matchText, note: note,
          specificity: InspectorCascade.specificity(matching: row),
          cascadeOrder: start + offset, distance: distance))
    }
  }

  func mergingMuted(_ muted: [[String: String]], into rules: [InspectorRule]) -> [InspectorRule] {
    var next = rules
    for row in muted {
      guard let selector = row["selector"], selector.count <= 2048,
        let property = row["property"], property.count <= 128,
        let value = row["value"], value.count <= 4110
      else { continue }
      let match = row["matchText"] ?? ""
      ensureInlineRule(selector: selector, match: match, rules: &next)
      guard let index = mutedRuleIndex(selector: selector, match: match, in: next) else {
        continue
      }
      if next[index].declarations.contains(where: { $0.name == property }) { continue }
      next[index].declarations.append(
        InspectorDeclaration(
          name: property, value: value, key: "muted-\(property)", disabled: true))
    }
    return next
  }

  private func ensureInlineRule(selector: String, match: String, rules: inout [InspectorRule]) {
    guard selector == "element.style", match.isEmpty,
      !rules.contains(where: { $0.selector == "element.style" && $0.editable })
    else { return }
    let id = (rules.map(\.id).max() ?? -1) + 1
    rules.insert(
      InspectorRule(
        id: id, selector: "element.style", source: "Inline overrides",
        declarations: [], origin: .inline, editable: true),
      at: 0)
  }

  private func mutedRuleIndex(selector: String, match: String, in rules: [InspectorRule]) -> Int? {
    if selector == "element.style", match.isEmpty,
      let index = rules.firstIndex(where: { $0.selector == "element.style" && $0.editable })
    {
      return index
    }
    let exact = rules.indices.filter { index in
      let rule = rules[index]
      return rule.selector == selector && (match.isEmpty || rule.matchText == match)
    }
    if exact.count == 1 { return exact[0] }
    guard !match.isEmpty else { return nil }
    let editable = rules.indices.filter { rules[$0].selector == selector && rules[$0].editable }
    if editable.count == 1 { return editable[0] }
    return nil
  }

  func declarations(_ style: [String: Any]) -> [InspectorDeclaration] {
    return ((style["cssProperties"] as? [[String: Any]]) ?? []).prefix(2048).enumerated().compactMap
    { index, row in
      guard row["implicit"] as? Bool != true,
        style["styleSheetId"] == nil || row["range"] != nil || row["text"] != nil,
        let name = row["name"] as? String, name.count <= 128,
        let value = row["value"] as? String, value.count <= 4096
      else { return nil }
      return InspectorDeclaration(
        name: name, value: value + (row["important"] as? Bool == true ? " !important" : ""),
        key: String(index), disabled: row["disabled"] as? Bool == true)
    }.prefix(120).map { $0 }
  }

  private func source(
    for sheet: String, selector: String, style: [String: Any], inspector: InspectorModel
  ) async -> String {
    if let cached = sources[sheet] { return cached }
    let generation = inspector.documentGeneration
    do {
      let cssText =
        style["cssText"] as? String
        ?? ((style["cssProperties"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        .joined(separator: "\n")
      if cssText.utf8.count <= 65_536 {
        let arguments = String(
          data: try JSONSerialization.data(withJSONObject: [selector, cssText]), encoding: .utf8)!
        if let url = try await inspector.evaluate(
          "globalThis.__shaarInspectorStyles.sourceFor(...\(arguments))") as? String, !url.isEmpty
        {
          guard inspector.documentGeneration == generation else { throw CancellationError() }
          sources[sheet] = url
          return url
        }
      }
      guard
        let text = try await inspector.call(
          "CSS.getStyleSheetText", params: ["styleSheetId": sheet])["text"] as? String,
        text.utf8.count <= 4_194_304
      else { return "Stylesheet \(sheet)" }
      if !resourcesLoaded {
        var next: [(String, String)] = []
        if let inline = try await inspector.evaluate("globalThis.__shaarInspectorStyles.sources()")
          as? [[String: String]]
        {
          next.append(
            contentsOf: inline.compactMap { row in
              guard let text = row["text"], let url = row["url"] else { return nil }
              return (text, url)
            })
        }
        let tree = try await inspector.call("Page.getResourceTree")
        var files: [(String, String)] = []
        func collect(_ tree: [String: Any], depth: Int = 0) {
          guard depth < 8, let frame = tree["frame"] as? [String: Any],
            let id = frame["id"] as? String
          else { return }
          for row in (tree["resources"] as? [[String: Any]] ?? []).prefix(256) {
            if row["type"] as? String == "Stylesheet", let url = row["url"] as? String,
              files.count < 32
            {
              files.append((id, url))
            }
          }
          for child in (tree["childFrames"] as? [[String: Any]] ?? []).prefix(32) {
            collect(child, depth: depth + 1)
          }
        }
        if let root = tree["frameTree"] as? [String: Any] { collect(root) }
        var total = 0
        let started = Date()
        for (frame, url) in files {
          guard !Task.isCancelled, inspector.isOpen, inspector.documentGeneration == generation
          else { throw CancellationError() }
          if Date().timeIntervalSince(started) > 5 { break }
          if let result = try? await inspector.call(
            "Page.getResourceContent", params: ["frameId": frame, "url": url]),
            result["base64Encoded"] as? Bool == false, let content = result["content"] as? String,
            content.utf8.count <= 4_194_304, total + content.utf8.count <= 8_388_608
          {
            next.append((content, url))
            total += content.utf8.count
          }
        }
        guard inspector.documentGeneration == generation else { throw CancellationError() }
        resources = next
        resourcesLoaded = true
      }
      let matches = Set(resources.filter { $0.0 == text }.map(\.1))
      let value = matches.count == 1 ? matches.first! : "Stylesheet \(sheet)"
      guard inspector.documentGeneration == generation else { throw CancellationError() }
      sources[sheet] = value
      return value
    } catch { return "Stylesheet \(sheet)" }
  }

  private func takeForcedNode() -> Int? {
    let node = forcedNodeID
    forcedPseudos = []
    forcedNodeID = nil
    return node
  }

  private func releaseForcedNode(_ node: Int?) async {
    guard let node, let inspector else { return }
    _ = try? await inspector.call(
      "CSS.forcePseudoState",
      params: ["nodeId": node, "forcedPseudoClasses": [String]()])
  }

  func togglePseudo(_ name: String) async {
    guard !forcing, !busy, InspectorPseudoForce.names.contains(name), let inspector,
      inspector.isOpen,
      let selection = inspector.selection, selection.locked
    else { return }
    forcing = true
    defer { forcing = false }
    let turningOn = !forcedPseudos.contains(name)
    var next = forcedPseudos
    if turningOn {
      next.insert(name)
    } else {
      next.remove(name)
    }
    let classes = InspectorPseudoForce.ordered(next)
    do {
      let node = try await inspector.withSelectedNode { nodeID in
        _ = try await inspector.call(
          "CSS.forcePseudoState",
          params: ["nodeId": nodeID, "forcedPseudoClasses": classes])
        return nodeID
      }
      guard inspector.isOpen, inspector.selection?.id == selection.id else { return }
      forcedPseudos = next
      forcedNodeID = classes.isEmpty ? nil : node
      failure = nil
      await refresh(force: true)
    } catch {
      if turningOn, inspector.isOpen, inspector.selection?.id == selection.id {
        failure = Self.failureMessage(for: error)
      }
    }
  }

  func edit(property: String, value: String, important: Bool) async {
    guard !Task.isCancelled, !busy, let inspector, let selection = inspector.selection,
      selection.locked
    else {
      return
    }
    do {
      let args: [Any] = [selection.id, property, value, important ? "important" : ""]
      let literal = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
      let result =
        try await inspector.evaluate("globalThis.__shaarInspectorStyles.edit(...\(literal))")
        as? [String: Any]
      guard result?["ok"] as? Bool == true else {
        throw InspectorFailure(
          InspectorL10n.display(result?["error"] as? String ?? "CSS could not be applied."))
      }
      await refresh(force: true)
      await inspector.refresh()
    } catch { failure = Self.failureMessage(for: error) }
  }

  func editRule(
    _ rule: InspectorRule, property: String, value: String, important: Bool,
    replacing: String? = nil
  ) async {
    if rule.origin == .inline {
      if let replacing, replacing != property {
        await edit(property: replacing, value: "", important: false)
        guard failure == nil else { return }
      }
      await edit(property: property, value: value, important: important)
      return
    }
    guard rule.editable, !busy, let inspector, let selection = inspector.selection, selection.locked
    else { return }
    await applyStyleResult(
      "editRule",
      arguments: [
        selection.id, rule.selector, rule.matchText, property, value, important ? "important" : "",
        replacing ?? "",
      ])
  }

  func setDeclaration(
    _ rule: InspectorRule, _ declaration: InspectorDeclaration, enabled: Bool
  ) async {
    guard !busy, let inspector, let selection = inspector.selection, selection.locked else {
      return
    }
    let selector = rule.origin == .inline ? "element.style" : rule.selector
    await applyStyleResult(
      "setEnabled",
      arguments: [
        selection.id, selector, rule.matchText, declaration.name, enabled,
      ])
  }

  func addRule(selector: String) async {
    guard !busy, let inspector, let selection = inspector.selection, selection.locked else {
      return
    }
    await applyStyleResult("addRule", arguments: [selection.id, selector])
  }

  private func applyStyleResult(_ name: String, arguments: [Any]) async {
    guard !Task.isCancelled, let inspector else { return }
    do {
      let literal = String(
        data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
      let result =
        try await inspector.evaluate("globalThis.__shaarInspectorStyles.\(name)(...\(literal))")
        as? [String: Any]
      guard result?["ok"] as? Bool == true else {
        throw InspectorFailure(
          InspectorL10n.display(result?["error"] as? String ?? "CSS could not be applied."))
      }
      await refresh(force: true)
      await inspector.refresh()
    } catch { failure = Self.failureMessage(for: error) }
  }

  func undo() async {
    guard !Task.isCancelled, !busy, let inspector else { return }
    do {
      let result =
        try await inspector.evaluate("globalThis.__shaarInspectorStyles.undo()") as? [String: Any]
      guard result?["ok"] as? Bool == true else {
        throw InspectorFailure(
          InspectorL10n.display(result?["error"] as? String ?? "CSS could not be restored."))
      }
      await refresh(force: true)
      await inspector.refresh()
    } catch { failure = Self.failureMessage(for: error) }
  }

  func clearOverlay(generation: Int? = nil) async {
    guard let inspector else { return }
    let expected = generation ?? inspector.documentGeneration
    guard inspector.documentGeneration == expected else { return }
    _ = try? await inspector.call(
      "Overlay.setShowGridOverlays", params: ["gridNodeHighlightConfigs": []])
    guard inspector.documentGeneration == expected else { return }
    _ = try? await inspector.call(
      "Overlay.setShowFlexOverlays", params: ["flexNodeHighlightConfigs": []])
    guard inspector.documentGeneration == expected else { return }
    overlay = false
  }

  func toggleOverlay() async {
    guard !Task.isCancelled, let inspector, canOverlay, inspector.isOpen,
      selectedID == inspector.selection?.id
    else {
      return
    }
    let generation = inspector.documentGeneration
    let identity = selectedID
    if overlay {
      await clearOverlay()
      return
    }
    do {
      try await inspector.withSelectedNode { node in
        _ = try await inspector.call("Overlay.enable")
        guard inspector.isOpen, inspector.documentGeneration == generation,
          inspector.selection?.id == identity
        else { throw CancellationError() }
        let color: [String: Any] = ["r": 139, "g": 92, "b": 246, "a": 0.9]
        if computed.contains(where: { $0.name == "display" && $0.value.contains("grid") }) {
          _ = try await inspector.call(
            "Overlay.setShowGridOverlays",
            params: [
              "gridNodeHighlightConfigs": [
                [
                  "nodeId": node,
                  "gridHighlightConfig": [
                    "showPositiveLineNumbers": true, "showTrackSizes": true, "rowLineColor": color,
                    "columnLineColor": color, "gridBorderColor": color,
                  ],
                ]
              ]
            ])
        } else {
          let line: [String: Any] = ["color": color, "pattern": "dashed"]
          _ = try await inspector.call(
            "Overlay.setShowFlexOverlays",
            params: [
              "flexNodeHighlightConfigs": [
                [
                  "nodeId": node,
                  "flexContainerHighlightConfig": [
                    "containerBorder": line, "itemSeparator": line, "lineSeparator": line,
                    "rowGapSpace": ["hatchColor": color], "columnGapSpace": ["hatchColor": color],
                  ],
                ]
              ]
            ])
        }
      }
      guard inspector.isOpen, inspector.documentGeneration == generation,
        inspector.selection?.id == identity
      else { throw CancellationError() }
      overlay = true
    } catch { failure = Self.failureMessage(for: error) }
  }

  func screenshot() async throws -> Data {
    guard !Task.isCancelled else { throw CancellationError() }
    guard !capturing else {
      throw InspectorFailure(InspectorL10n.string("An element capture is already in progress."))
    }
    capturing = true
    defer { capturing = false }
    guard let inspector, let selection = inspector.selection, selection.locked else {
      throw InspectorFailure(InspectorL10n.string("Lock an element first."))
    }
    let generation = inspector.documentGeneration
    guard
      let clip = try await inspector.evaluate(
        "globalThis.__shaarInspectorStyles.clip(\(selection.id))") as? [String: Any],
      let x = clip["x"] as? Double, let y = clip["y"] as? Double,
      let width = clip["width"] as? Double, let height = clip["height"] as? Double,
      let dpr = clip["devicePixelRatio"] as? Double,
      [x, y, width, height, dpr].allSatisfy(\.isFinite), width > 0, height > 0, dpr > 0,
      width * height * 4 <= 16_777_216, max(width, height) * 2 <= 16_384
    else {
      throw InspectorFailure(
        InspectorL10n.string("Select an element smaller than 16 megapixels at 2×."))
    }
    guard inspector.documentGeneration == generation, inspector.selection?.id == selection.id else {
      throw CancellationError()
    }
    let hadOverlay = overlay
    await clearOverlay()
    guard inspector.documentGeneration == generation, inspector.selection?.id == selection.id else {
      throw CancellationError()
    }
    _ = try await inspector.evaluate("globalThis.__shaarInspectorV2.visible(false); true")
    do {
      let result = try await inspector.call(
        "Page.captureScreenshot",
        params: [
          "format": "png", "captureBeyondViewport": true,
          "clip": ["x": x, "y": y, "width": width, "height": height, "scale": 2 / dpr],
        ])
      guard inspector.documentGeneration == generation, inspector.selection?.id == selection.id
      else { throw CancellationError() }
      _ = try? await inspector.evaluate("globalThis.__shaarInspectorV2?.visible(true); true")
      if hadOverlay { await toggleOverlay() }
      guard let encoded = result["data"] as? String, encoded.count <= 44_739_244,
        let data = Data(base64Encoded: encoded)
      else {
        throw InspectorFailure(InspectorL10n.string("Chromium could not capture this element."))
      }
      return data
    } catch {
      if inspector.documentGeneration == generation {
        _ = try? await inspector.evaluate("globalThis.__shaarInspectorV2?.visible(true); true")
        if hadOverlay, inspector.selection?.id == selection.id { await toggleOverlay() }
      }
      throw error
    }
  }

  func saveScreenshot() async {
    do {
      let data = try await screenshot()
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.png]
      panel.nameFieldStringValue = "element@2x.png"
      guard await panel.begin() == .OK, let url = panel.url else { return }
      try data.write(to: url, options: .atomic)
    } catch { failure = Self.failureMessage(for: error) }
  }

  static func failureMessage(for error: Error) -> String {
    if error is InspectorFailure || error is DeveloperModeFailure {
      return InspectorL10n.display(error.localizedDescription)
    }
    return InspectorL10n.string("Could not complete the page style change. Try again.")
  }

  var exported: [InspectorDeclaration] {
    let names =
      [
        "display", "position", "box-sizing", "width", "height",
        "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
        "border-top-left-radius", "border-top-right-radius", "border-bottom-left-radius",
        "border-bottom-right-radius",
        "background-color", "color", "font-family", "font-size", "font-weight",
        "line-height", "letter-spacing",
      ]
      + layout.map(\.name)
    var seen = Set<String>()
    return names.compactMap { name in
      guard seen.insert(name).inserted else { return nil }
      return computed.first { $0.name == name }
    }
  }
  var css: String {
    let selector = inspector?.selection?.css ?? "element"
    return selector + " {\n" + exported.map { "  \($0.name): \($0.value);" }.joined(separator: "\n")
      + "\n}"
  }
  var tailwind: String {
    exported.map { property in
      let value = property.value.replacingOccurrences(of: "_", with: #"\_"#)
        .replacingOccurrences(of: " ", with: "_")
      return "[\(property.name):\(value)]"
    }.joined(separator: " ")
  }
}
