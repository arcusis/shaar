// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarStackingStyle: Equatable, Sendable {
  var position = ""
  var zIndex = ""
  var opacity = ""
  var transform = ""
  var filter = ""
  var perspective = ""
  var mixBlendMode = ""
  var isolation = ""
  var willChange = ""
  var contain = ""
  var backdropFilter = ""
  var clipPath = ""
  var maskImage = ""
  var display = ""
}

struct ShaarStackingElement: Equatable, Sendable, Identifiable {
  var id: Int { nodeID }
  var nodeID: Int
  var parentID: Int?
  var name: String
  var depth: Int
  var bounds: CGRect?
  var style: ShaarStackingStyle
  var parentDisplay: String
  /// Blink's id. DOM.getDocument drops frontend node ids and keeps this one.
  var backendNodeID: Int?
}

struct ShaarStackingSnapshot: Equatable, Sendable {
  var elements: [ShaarStackingElement]
  var clipped: Bool
}

struct ShaarStackingSlab: Equatable, Sendable, Identifiable {
  var id: Int { nodeID }
  var nodeID: Int
  var name: String
  var depth: Int
  var bounds: CGRect
  var zIndex: Int?
  var createsContext: Bool
  var reasons: [String]
  var level: Double
  var paintOrder: Int
}

enum ShaarStackingMode: String, CaseIterable, Sendable {
  case dom = "DOM"
  case zIndex = "Z-index"
}

struct ShaarStackingCamera: Equatable, Sendable {
  var yaw: Double
  var pitch: Double
  var zoom: Double
  var panX: Double
  var panY: Double

  static let orbit = ShaarStackingCamera(yaw: -0.65, pitch: 0.58, zoom: 1, panX: 0, panY: 0)
}

struct ShaarStackingFailure: LocalizedError {
  var errorDescription: String?
  init(_ key: String) { errorDescription = ShellL10n.string(key) }
}

enum ShaarStackingContext {
  static func reasons(for element: ShaarStackingElement, isRoot: Bool) -> [String] {
    if isRoot { return ["root"] }
    var reasons: [String] = []
    let position = normalized(element.style.position)
    let zIndex = normalized(element.style.zIndex)
    let positioned = position == "absolute" || position == "relative"
    if positioned && hasZIndex(zIndex) {
      reasons.append("z-index: \(element.style.zIndex)")
    }
    if position == "fixed" || position == "sticky" {
      reasons.append("position: \(position)")
      if hasZIndex(zIndex) { reasons.append("z-index: \(element.style.zIndex)") }
    }
    let parent = normalized(element.parentDisplay)
    if flexOrGrid(parent) && hasZIndex(zIndex) {
      reasons.append("\(parent) item z-index")
    }
    if opacityCreates(element.style.opacity) {
      reasons.append("opacity: \(element.style.opacity)")
    }
    appendEffect("transform", element.style.transform, to: &reasons)
    appendEffect("filter", element.style.filter, to: &reasons)
    appendEffect("perspective", element.style.perspective, to: &reasons)
    appendEffect("backdrop-filter", element.style.backdropFilter, to: &reasons)
    appendEffect("clip-path", element.style.clipPath, to: &reasons)
    appendEffect("mask", element.style.maskImage, to: &reasons)
    let blend = normalized(element.style.mixBlendMode)
    if !blend.isEmpty && blend != "normal" { reasons.append("mix-blend-mode") }
    if normalized(element.style.isolation) == "isolate" { reasons.append("isolation") }
    if willChangeCreates(element.style.willChange) { reasons.append("will-change") }
    if containCreates(element.style.contain) { reasons.append("contain") }
    return reasons
  }

  static func parsedZIndex(_ value: String) -> Int? {
    let text = normalized(value)
    if text.isEmpty || text == "auto" { return nil }
    return Int(text)
  }

  private static func appendEffect(_ name: String, _ value: String, to reasons: inout [String]) {
    guard effectCreates(value) else { return }
    reasons.append(name)
  }

  private static func hasZIndex(_ value: String) -> Bool {
    !value.isEmpty && value != "auto"
  }

  private static func flexOrGrid(_ display: String) -> Bool {
    display == "flex" || display == "inline-flex" || display == "grid" || display == "inline-grid"
  }

  private static func opacityCreates(_ value: String) -> Bool {
    guard let number = Double(normalized(value)) else { return false }
    return number >= 0 && number < 1
  }

  private static func effectCreates(_ value: String) -> Bool {
    let text = normalized(value)
    return !text.isEmpty && text != "none" && text != "auto"
  }

  private static func willChangeCreates(_ value: String) -> Bool {
    let triggers: Set<String> = [
      "transform", "opacity", "filter", "perspective", "contain", "z-index",
    ]
    return tokens(value).contains { triggers.contains($0) }
  }

  private static func containCreates(_ value: String) -> Bool {
    let names = tokens(value)
    return names.contains("paint") || names.contains("strict") || names.contains("content")
  }

  private static func tokens(_ value: String) -> [String] {
    normalized(value).split { !$0.isLetter && $0 != "-" }.map(String.init)
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

enum ShaarStackingLayout {
  static let domStep = 26.0
  static let zStep = 34.0
  static let innerStep = 7.0
  static let maximumNodes = 180

  static func slabs(
    from elements: [ShaarStackingElement], mode: ShaarStackingMode
  ) -> [ShaarStackingSlab] {
    let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.nodeID, $0) })
    let children = childIDs(elements)
    let roots = elements.filter { element in
      guard let parentID = element.parentID else { return true }
      return byID[parentID] == nil
    }
    var built: [ShaarStackingSlab] = []
    var order = 0
    for root in roots {
      walk(
        root.nodeID, parentContext: 0, depthInContext: 0, isRoot: true, children: children,
        byID: byID, mode: mode, order: &order, slabs: &built)
    }
    return built
  }

  private static func childIDs(_ elements: [ShaarStackingElement]) -> [Int: [Int]] {
    var children: [Int: [Int]] = [:]
    for element in elements {
      guard let parentID = element.parentID else { continue }
      children[parentID, default: []].append(element.nodeID)
    }
    return children
  }

  private static func walk(
    _ nodeID: Int, parentContext: Double, depthInContext: Int, isRoot: Bool,
    children: [Int: [Int]], byID: [Int: ShaarStackingElement], mode: ShaarStackingMode,
    order: inout Int, slabs: inout [ShaarStackingSlab]
  ) {
    guard let element = byID[nodeID] else { return }
    let reasons = ShaarStackingContext.reasons(for: element, isRoot: isRoot)
    let creates = !reasons.isEmpty
    let zIndex = ShaarStackingContext.parsedZIndex(element.style.zIndex)
    let level = level(
      creates: creates, zIndex: zIndex, depth: element.depth, depthInContext: depthInContext,
      parentContext: parentContext, isRoot: isRoot, mode: mode)
    if let bounds = element.bounds, bounds.width >= 1, bounds.height >= 1 {
      slabs.append(
        ShaarStackingSlab(
          nodeID: element.nodeID, name: element.name, depth: element.depth, bounds: bounds,
          zIndex: zIndex, createsContext: creates, reasons: reasons, level: level,
          paintOrder: order))
      order += 1
    }
    let nextContext = creates ? level : parentContext
    let nextDepth = creates ? 0 : depthInContext + 1
    for child in children[nodeID] ?? [] {
      walk(
        child, parentContext: nextContext, depthInContext: nextDepth, isRoot: false,
        children: children, byID: byID, mode: mode, order: &order, slabs: &slabs)
    }
  }

  private static func level(
    creates: Bool, zIndex: Int?, depth: Int, depthInContext: Int, parentContext: Double,
    isRoot: Bool, mode: ShaarStackingMode
  ) -> Double {
    if mode == .dom { return Double(depth) * domStep }
    if isRoot { return 0 }
    if creates {
      if let zIndex, zIndex != 0 { return parentContext + Double(zIndex) * zStep }
      return parentContext + innerStep
    }
    return parentContext + innerStep + Double(depthInContext) * innerStep
  }
}

enum ShaarStackingProjection {
  static func project(
    _ point: CGPoint, level: Double, camera: ShaarStackingCamera
  ) -> CGPoint {
    let x = Double(point.x)
    let y = Double(point.y)
    let z = level
    let cosYaw = cos(camera.yaw)
    let sinYaw = sin(camera.yaw)
    let cosPitch = cos(camera.pitch)
    let sinPitch = sin(camera.pitch)
    let turnedX = x * cosYaw + z * sinYaw
    let turnedZ = -x * sinYaw + z * cosYaw
    let turnedY = y * cosPitch - turnedZ * sinPitch
    return CGPoint(x: turnedX * camera.zoom + camera.panX, y: turnedY * camera.zoom + camera.panY)
  }

  static func quad(bounds: CGRect, level: Double, camera: ShaarStackingCamera) -> [CGPoint] {
    [
      project(CGPoint(x: bounds.minX, y: bounds.minY), level: level, camera: camera),
      project(CGPoint(x: bounds.maxX, y: bounds.minY), level: level, camera: camera),
      project(CGPoint(x: bounds.maxX, y: bounds.maxY), level: level, camera: camera),
      project(CGPoint(x: bounds.minX, y: bounds.maxY), level: level, camera: camera),
    ]
  }

  static func contains(_ point: CGPoint, quad: [CGPoint]) -> Bool {
    guard quad.count >= 3 else { return false }
    var inside = false
    var previous = quad[quad.count - 1]
    for corner in quad {
      let crosses = (corner.y > point.y) != (previous.y > point.y)
      if crosses && previous.y != corner.y {
        let xCross =
          (previous.x - corner.x) * (point.y - corner.y) / (previous.y - corner.y) + corner.x
        if point.x < xCross { inside.toggle() }
      }
      previous = corner
    }
    return inside
  }

  static func hit(
    _ point: CGPoint, slabs: [ShaarStackingSlab], camera: ShaarStackingCamera
  ) -> ShaarStackingSlab? {
    var best: ShaarStackingSlab?
    for slab in slabs {
      let corners = quad(bounds: slab.bounds, level: slab.level, camera: camera)
      guard contains(point, quad: corners) else { continue }
      guard let current = best else {
        best = slab
        continue
      }
      if slab.level < current.level { continue }
      if slab.level == current.level && slab.paintOrder < current.paintOrder { continue }
      best = slab
    }
    return best
  }

  static func fitted(
    slabs: [ShaarStackingSlab], in size: CGSize, orbit: ShaarStackingCamera
  ) -> ShaarStackingCamera {
    var camera = orbit
    camera.zoom = 1
    camera.panX = 0
    camera.panY = 0
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    var any = false
    for slab in slabs {
      for corner in quad(bounds: slab.bounds, level: slab.level, camera: camera) {
        any = true
        minX = min(minX, corner.x)
        minY = min(minY, corner.y)
        maxX = max(maxX, corner.x)
        maxY = max(maxY, corner.y)
      }
    }
    guard any, size.width > 48, size.height > 48 else { return orbit }
    let padding = 24.0
    let width = max(maxX - minX, 1)
    let height = max(maxY - minY, 1)
    let roomX = max(Double(size.width) - padding * 2, 1)
    let roomY = max(Double(size.height) - padding * 2, 1)
    let zoom = min(roomX / width, roomY / height)
    camera.zoom = zoom
    camera.panX = padding - minX * zoom + (roomX - width * zoom) / 2
    camera.panY = padding - minY * zoom + (roomY - height * zoom) / 2
    return camera
  }
}

@MainActor enum ShaarStackingCapture {
  private static let skipped: Set<String> = [
    "SCRIPT", "STYLE", "LINK", "META", "TITLE", "NOSCRIPT", "TEMPLATE", "BR", "WBR", "HEAD",
  ]

  static func collect(
    call: @MainActor (String, [String: Any]) async throws -> [String: Any]
  ) async throws -> ShaarStackingSnapshot {
    _ = try await call("DOM.enable", [:])
    _ = try await call("CSS.enable", [:])
    _ = try await call("Overlay.enable", [:])
    let document = try await call("DOM.getDocument", ["depth": -1, "pierce": false])
    guard let root = document["root"] as? [String: Any] else {
      throw ShaarStackingFailure("DOM snapshot was empty")
    }
    let kept = keptNodes(in: root)
    var boxes: [Int: [String: Any]] = [:]
    var styles: [Int: [String: Any]] = [:]
    for node in kept.nodes {
      boxes[node.nodeID] = try? await call("DOM.getBoxModel", ["nodeId": node.nodeID])
      styles[node.nodeID] = try? await call(
        "CSS.getComputedStyleForNode", ["nodeId": node.nodeID])
    }
    return ShaarStackingSnapshot(
      elements: elements(nodes: kept.nodes, boxes: boxes, styles: styles), clipped: kept.clipped)
  }

  static func elements(
    from document: [String: Any], boxes: [Int: [String: Any]], styles: [Int: [String: Any]]
  ) -> [ShaarStackingElement] {
    guard let root = document["root"] as? [String: Any] else { return [] }
    return elements(nodes: keptNodes(in: root).nodes, boxes: boxes, styles: styles)
  }

  private struct RawNode {
    var nodeID: Int
    var backendNodeID: Int?
    var parentID: Int?
    var parentIsElement: Bool
    var name: String
    var attributes: [String]
    var depth: Int
  }

  private static func elements(
    nodes: [RawNode], boxes: [Int: [String: Any]], styles: [Int: [String: Any]]
  ) -> [ShaarStackingElement] {
    var built: [ShaarStackingElement] = []
    for node in nodes {
      built.append(
        ShaarStackingElement(
          nodeID: node.nodeID, parentID: node.parentID, name: label(node), depth: node.depth,
          bounds: boxes[node.nodeID].flatMap(bounds(from:)),
          style: style(from: styles[node.nodeID] ?? [:]), parentDisplay: "",
          backendNodeID: node.backendNodeID))
    }
    let displayByID = Dictionary(uniqueKeysWithValues: built.map { ($0.nodeID, $0.style.display) })
    for index in built.indices {
      guard let parentID = built[index].parentID else { continue }
      built[index].parentDisplay = displayByID[parentID] ?? ""
    }
    return built
  }

  private static func keptNodes(in root: [String: Any]) -> (nodes: [RawNode], clipped: Bool) {
    var flat: [RawNode] = []
    flatten(root, parentID: nil, parentIsElement: false, depth: 0, into: &flat)
    let eligible = prefix(flat, limit: Int.max)
    let kept = prefix(flat, limit: ShaarStackingLayout.maximumNodes)
    return (kept, eligible.count > kept.count)
  }

  private static func flatten(
    _ node: [String: Any], parentID: Int?, parentIsElement: Bool, depth: Int,
    into nodes: inout [RawNode]
  ) {
    let type = integer(node["nodeType"]) ?? 0
    let nodeID = integer(node["nodeId"]) ?? 0
    let name = node["nodeName"] as? String ?? ""
    let isElement = type == 1 && nodeID > 0
    if isElement && !skipped.contains(name.uppercased()) {
      let backend = integer(node["backendNodeId"]) ?? 0
      nodes.append(
        RawNode(
          nodeID: nodeID, backendNodeID: backend > 0 ? backend : nil, parentID: parentID,
          parentIsElement: parentIsElement, name: name, attributes: strings(node["attributes"]),
          depth: depth))
    }
    let childParent = isElement ? nodeID : parentID
    let childParentIsElement = isElement ? true : parentIsElement
    let childDepth = isElement ? depth + 1 : depth
    for child in node["children"] as? [[String: Any]] ?? [] {
      flatten(
        child, parentID: childParent, parentIsElement: childParentIsElement, depth: childDepth,
        into: &nodes)
    }
    if let content = node["contentDocument"] as? [String: Any] {
      flatten(
        content, parentID: childParent, parentIsElement: childParentIsElement, depth: childDepth,
        into: &nodes)
    }
  }

  private static func prefix(_ nodes: [RawNode], limit: Int) -> [RawNode] {
    var kept: [RawNode] = []
    var ids: Set<Int> = []
    for node in nodes {
      if kept.count >= limit { break }
      if node.parentIsElement, let parentID = node.parentID, !ids.contains(parentID) { continue }
      kept.append(node)
      ids.insert(node.nodeID)
    }
    return kept
  }

  private static func label(_ node: RawNode) -> String {
    var text = node.name.lowercased()
    var identifier = ""
    var classes: [String] = []
    var index = 0
    while index + 1 < node.attributes.count {
      let key = node.attributes[index]
      let value = node.attributes[index + 1]
      if key == "id", !value.isEmpty { identifier = value }
      if key == "class" {
        classes = value.split(separator: " ").prefix(2).map(String.init)
      }
      index += 2
    }
    if !identifier.isEmpty { text += "#\(identifier)" }
    for name in classes { text += ".\(name)" }
    return text
  }

  static func bounds(from reply: [String: Any]) -> CGRect? {
    guard let model = reply["model"] as? [String: Any] else { return nil }
    let quad = (model["border"] as? [Any]) ?? (model["content"] as? [Any]) ?? []
    guard quad.count >= 6 else { return nil }
    var xs: [Double] = []
    var ys: [Double] = []
    var index = 0
    while index + 1 < quad.count {
      if let x = number(quad[index]), let y = number(quad[index + 1]) {
        xs.append(x)
        ys.append(y)
      }
      index += 2
    }
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return nil }
    let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    guard rect.width >= 1, rect.height >= 1 else { return nil }
    return rect
  }

  static func style(from reply: [String: Any]) -> ShaarStackingStyle {
    var values: [String: String] = [:]
    for row in reply["computedStyle"] as? [[String: Any]] ?? [] {
      guard let name = row["name"] as? String, let value = row["value"] as? String else { continue }
      values[name] = value
    }
    return ShaarStackingStyle(
      position: values["position"] ?? "", zIndex: values["z-index"] ?? "",
      opacity: values["opacity"] ?? "", transform: values["transform"] ?? "",
      filter: values["filter"] ?? "", perspective: values["perspective"] ?? "",
      mixBlendMode: values["mix-blend-mode"] ?? "", isolation: values["isolation"] ?? "",
      willChange: values["will-change"] ?? "", contain: values["contain"] ?? "",
      backdropFilter: values["backdrop-filter"] ?? "", clipPath: values["clip-path"] ?? "",
      maskImage: values["mask-image"] ?? "", display: values["display"] ?? "")
  }

  private static func strings(_ value: Any?) -> [String] {
    guard let values = value as? [Any] else { return [] }
    return values.compactMap { $0 as? String }
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
  }
}

@MainActor @Observable
final class ShaarStackingModel {
  private(set) var slabs: [ShaarStackingSlab] = []
  private(set) var elements: [ShaarStackingElement] = []
  private(set) var loading = false
  private(set) var captured = false
  private(set) var clipped = false
  private(set) var selectedID: Int?
  private(set) var highlightedID: Int?
  private(set) var fitGeneration = 0
  var failure: String?
  var mode: ShaarStackingMode = .zIndex {
    didSet {
      guard mode != oldValue else { return }
      rebuild()
    }
  }
  var camera = ShaarStackingCamera.orbit
  @ObservationIgnored private var capturePage:
    (@MainActor () async throws -> ShaarStackingSnapshot)?
  @ObservationIgnored private var selectNode: (@MainActor (Int) async -> Bool)?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var selectionGeneration = 0

  var contexts: [ShaarStackingSlab] { slabs.filter(\.createsContext) }

  var selected: ShaarStackingSlab? { slabs.first { $0.nodeID == selectedID } }

  func attach(
    capture: @escaping @MainActor () async throws -> ShaarStackingSnapshot,
    select: @escaping @MainActor (Int) async -> Bool
  ) {
    capturePage = capture
    selectNode = select
  }

  func present(_ snapshot: ShaarStackingSnapshot, mode: ShaarStackingMode = .zIndex) {
    generation += 1
    loading = false
    elements = snapshot.elements
    clipped = snapshot.clipped
    captured = true
    failure = nil
    selectedID = nil
    highlightedID = nil
    if self.mode != mode {
      self.mode = mode
    } else {
      rebuild()
    }
  }

  func capture() async {
    guard !loading else { return }
    guard let capturePage else {
      failure = ShellL10n.string("Snapshot needs a page")
      return
    }
    generation += 1
    let token = generation
    loading = true
    failure = nil
    defer { if token == generation { loading = false } }
    do {
      let snapshot = try await capturePage()
      guard token == generation else { return }
      elements = snapshot.elements
      clipped = snapshot.clipped
      captured = true
      selectedID = nil
      highlightedID = nil
      rebuild()
    } catch is CancellationError {
      return
    } catch {
      guard token == generation else { return }
      failure = error.localizedDescription
    }
  }

  func select(_ nodeID: Int) {
    guard slabs.contains(where: { $0.nodeID == nodeID }) else { return }
    selectedID = nodeID
    selectionGeneration += 1
    let token = selectionGeneration
    guard let selectNode else {
      highlightedID = nodeID
      failure = nil
      return
    }
    Task {
      let highlighted = await selectNode(nodeID)
      guard token == selectionGeneration else { return }
      if highlighted {
        highlightedID = nodeID
        failure = nil
      } else {
        highlightedID = nil
        failure = ShellL10n.string("The element is not in the Elements tree yet.")
      }
    }
  }

  func hit(_ point: CGPoint) {
    guard let slab = ShaarStackingProjection.hit(point, slabs: slabs, camera: camera) else {
      return
    }
    select(slab.nodeID)
  }

  func fit(in size: CGSize) {
    guard !slabs.isEmpty else { return }
    camera = ShaarStackingProjection.fitted(slabs: slabs, in: size, orbit: .orbit)
  }

  func reset() {
    clearPage()
    capturePage = nil
    selectNode = nil
  }

  /// Drops the snapshot when the page changes. The capture callback stays attached.
  func clearPage() {
    generation += 1
    selectionGeneration += 1
    slabs = []
    elements = []
    loading = false
    captured = false
    clipped = false
    selectedID = nil
    highlightedID = nil
    failure = nil
    camera = .orbit
  }

  private func rebuild() {
    slabs = ShaarStackingLayout.slabs(from: elements, mode: mode)
    fitGeneration += 1
  }
}

struct ShaarStackingPanel: View {
  @Bindable var model: ShaarStackingModel
  var showInElements: () -> Void = {}
  @State private var orbitStart: ShaarStackingCamera?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      toolbar
      Divider()
      bodyContent
    }
    .accessibilityIdentifier("shaar.devtools.stacking")
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Button(ShellL10n.string("Capture snapshot"), action: { Task { await model.capture() } })
        .disabled(model.loading)
        .controlSize(.small)
        .accessibilityIdentifier("shaar.devtools.stacking.capture")
      Picker(ShellL10n.string("3D view"), selection: $model.mode) {
        ForEach(ShaarStackingMode.allCases, id: \.self) { mode in
          Text(ShellL10n.string(mode.rawValue)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 160)
      .labelsHidden()
      .accessibilityIdentifier("shaar.devtools.stacking.mode")
      if model.captured {
        Text(status)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(ShellL10n.string("Show in Elements"), action: showInElements)
        .disabled(model.selectedID == nil)
        .controlSize(.small)
        .accessibilityIdentifier("shaar.devtools.stacking.showElements")
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  @ViewBuilder private var bodyContent: some View {
    if model.loading {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("shaar.devtools.stacking.loading")
    } else if let failure, !model.captured {
      failureText(failure)
    } else if !model.captured {
      empty
    } else if model.slabs.isEmpty {
      failureText(ShellL10n.string("No visible elements in this snapshot."))
    } else {
      HStack(spacing: 0) {
        canvas
        Divider()
        contextList
      }
    }
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Text(ShellL10n.string("Capture a snapshot to see DOM depth and stacking contexts."))
        .font(.system(size: 12, weight: .medium))
      Text(ShellL10n.string("Drag to rotate. Click a slab to select it in Elements."))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func failureText(_ message: String) -> some View {
    Text(verbatim: message)
      .font(.system(size: 12))
      .foregroundStyle(.primary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
      .accessibilityIdentifier("shaar.devtools.stacking.failure")
  }

  private var canvas: some View {
    GeometryReader { geometry in
      Canvas { context, _ in
        draw(in: context)
      }
      .gesture(orbit)
      .simultaneousGesture(SpatialTapGesture().onEnded { event in model.hit(event.location) })
      .onAppear { model.fit(in: geometry.size) }
      .onChange(of: model.fitGeneration) { _, _ in model.fit(in: geometry.size) }
      .accessibilityIdentifier("shaar.devtools.stacking.canvas")
      .accessibilityLabel(ShellL10n.string("3D view"))
    }
  }

  private var orbit: some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        if orbitStart == nil { orbitStart = model.camera }
        guard let start = orbitStart else { return }
        var camera = start
        camera.yaw = start.yaw + Double(value.translation.width) * 0.008
        let pitch = start.pitch + Double(value.translation.height) * 0.008
        camera.pitch = min(1.2, max(0.2, pitch))
        model.camera = camera
      }
      .onEnded { _ in orbitStart = nil }
  }

  private func draw(in context: GraphicsContext) {
    let ordered = model.slabs.sorted(by: drawsBefore)
    for slab in ordered {
      let corners = ShaarStackingProjection.quad(
        bounds: slab.bounds, level: slab.level, camera: model.camera)
      let path = slabPath(corners)
      let selected = slab.nodeID == model.selectedID
      context.fill(path, with: .color(fill(for: slab).opacity(selected ? 0.86 : 0.55)))
      context.stroke(
        path, with: .color(Color.primary.opacity(selected ? 0.95 : 0.35)),
        lineWidth: selected ? 2 : 1)
      if let anchor = corners.first, slab.bounds.width > 36, slab.createsContext || selected {
        context.draw(
          Text(verbatim: slab.name).font(.system(size: 10, weight: .medium)),
          at: anchor, anchor: .topLeading)
      }
    }
  }

  private func drawsBefore(_ lhs: ShaarStackingSlab, _ rhs: ShaarStackingSlab) -> Bool {
    if lhs.level == rhs.level { return lhs.paintOrder < rhs.paintOrder }
    return lhs.level < rhs.level
  }

  private func slabPath(_ corners: [CGPoint]) -> Path {
    var path = Path()
    guard let first = corners.first else { return path }
    path.move(to: first)
    for corner in corners.dropFirst() { path.addLine(to: corner) }
    path.closeSubpath()
    return path
  }

  private func fill(for slab: ShaarStackingSlab) -> Color {
    let palette: [Color] = [
      Color(red: 0.20, green: 0.42, blue: 0.74),
      Color(red: 0.16, green: 0.52, blue: 0.46),
      Color(red: 0.70, green: 0.40, blue: 0.16),
      Color(red: 0.46, green: 0.30, blue: 0.62),
      Color(red: 0.55, green: 0.22, blue: 0.30),
    ]
    return palette[abs(slab.nodeID) % palette.count]
  }

  private var contextList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        Text(ShellL10n.string("Stacking contexts"))
          .font(.system(size: 11, weight: .semibold))
          .padding(.bottom, 4)
        if model.clipped {
          Text(ShellL10n.string("This snapshot stops at the first 180 elements."))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        if let failure = model.failure {
          Text(verbatim: failure)
            .font(.system(size: 10))
            .foregroundStyle(.primary)
        }
        ForEach(model.contexts) { slab in
          contextRow(slab)
        }
        if let selected = model.selected, !selected.createsContext {
          contextRow(selected)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 248)
    .accessibilityIdentifier("shaar.devtools.stacking.list")
  }

  private func contextRow(_ slab: ShaarStackingSlab) -> some View {
    Button {
      model.select(slab.nodeID)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: slab.name)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .lineLimit(1)
        Text(verbatim: detail(slab))
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background {
        if slab.nodeID == model.selectedID {
          RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("shaar.devtools.stacking.slab.\(slab.nodeID)")
    .accessibilityLabel(Text(verbatim: slab.name))
  }

  private func detail(_ slab: ShaarStackingSlab) -> String {
    let zIndex = slab.zIndex.map(String.init) ?? "auto"
    return "z-index \(zIndex) · \(slab.reasons.joined(separator: ", "))"
  }

  private var status: String {
    ShellL10n.format(
      "%d elements, %d stacking contexts",
      arguments: [.integer(model.slabs.count), .integer(model.contexts.count)])
  }

  private var failure: String? { model.failure }
}
