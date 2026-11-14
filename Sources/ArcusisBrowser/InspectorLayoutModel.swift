// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

struct InspectorLayoutContainer: Identifiable, Equatable, Decodable {
  enum Kind: String, Decodable { case grid, flex }
  let key: String
  let tag: String
  let elementID: String
  let classes: [String]
  let kind: Kind
  var id: String { key }

  enum CodingKeys: String, CodingKey {
    case key
    case tag
    case elementID = "id"
    case classes
    case kind
  }

  static func title(tag: String, elementID: String, classes: [String]) -> String {
    var text = tag
    if !elementID.isEmpty {
      text += "#"
      text += elementID
    }
    for name in classes.prefix(2) {
      text += "."
      text += name
    }
    return text
  }

  var title: String { Self.title(tag: tag, elementID: elementID, classes: classes) }
}

@MainActor @Observable
final class InspectorLayoutModel {
  private(set) var containers: [InspectorLayoutContainer] = []
  private(set) var showLineNumbers = true
  private(set) var showTrackSizes = true
  private(set) var showAreaNames = false
  private(set) var failure: String?
  private(set) var enabled: Set<String> = []
  @ObservationIgnored private weak var inspector: InspectorModel?
  @ObservationIgnored private var pinnedLock: Int?
  @ObservationIgnored private var applied = false
  @ObservationIgnored private var epoch = 0
  @ObservationIgnored private var installedGeneration = -1
  @ObservationIgnored private var scanning = false
  @ObservationIgnored private(set) var tail: Task<Void, Never>?

  init(inspector: InspectorModel) { self.inspector = inspector }

  /// Hover and the first lock do not count as changing elements. A different locked id does.
  static func shouldClear(pinned: Int?, locked: Int?) -> Bool {
    guard let pinned, let locked else { return false }
    return pinned != locked
  }

  static func overlayColor() -> [String: Any] {
    ["r": 139, "g": 92, "b": 246, "a": 0.9]
  }

  static func gridHighlightConfig(lineNumbers: Bool, trackSizes: Bool, areaNames: Bool)
    -> [String: Any]
  {
    let color = overlayColor()
    return [
      "showPositiveLineNumbers": lineNumbers,
      "showTrackSizes": trackSizes,
      "showAreaNames": areaNames,
      "rowLineColor": color,
      "columnLineColor": color,
      "gridBorderColor": color,
    ]
  }

  static func flexHighlightConfig() -> [String: Any] {
    let color = overlayColor()
    let line: [String: Any] = ["color": color, "pattern": "dashed"]
    let hatch: [String: Any] = ["hatchColor": color]
    return [
      "containerBorder": line,
      "itemSeparator": line,
      "lineSeparator": line,
      "rowGapSpace": hatch,
      "columnGapSpace": hatch,
    ]
  }

  func isOn(_ key: String) -> Bool { enabled.contains(key) }

  func refresh() async {
    guard !scanning, let inspector, inspector.isOpen else { return }
    scanning = true
    defer { scanning = false }
    let generation = inspector.documentGeneration
    let stamp = epoch
    do {
      try await install(generation: generation)
      guard epoch == stamp, inspector.isOpen, inspector.documentGeneration == generation else {
        return
      }
      guard
        let rows = try await inspector.evaluate("globalThis.__shaarInspectorLayout.read()"),
        JSONSerialization.isValidJSONObject(rows)
      else {
        noteFailure(generation: generation, stamp: stamp)
        return
      }
      let decoded = try JSONDecoder().decode(
        [InspectorLayoutContainer].self, from: JSONSerialization.data(withJSONObject: rows))
      guard epoch == stamp, inspector.isOpen, inspector.documentGeneration == generation else {
        return
      }
      containers = decoded
      let live = Set(decoded.map(\.key))
      let dropped = enabled.subtracting(live)
      if !dropped.isEmpty { enabled.subtract(dropped) }
      failure = nil
      if !dropped.isEmpty || !enabled.isEmpty {
        await enqueue(generation: generation) {
          await self.push(generation: generation, stamp: self.epoch)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      if unavailable(error) { return }
      noteFailure(generation: generation, stamp: stamp)
    }
  }

  func toggle(_ key: String) async {
    guard let inspector, inspector.isOpen else { return }
    if enabled.contains(key) {
      enabled.remove(key)
      if enabled.isEmpty { pinnedLock = nil }
    } else {
      guard containers.contains(where: { $0.key == key }) else { return }
      if enabled.isEmpty { pinnedLock = lockedSelectionID() }
      enabled.insert(key)
    }
    let generation = inspector.documentGeneration
    await enqueue(generation: generation) {
      await self.push(generation: generation, stamp: self.epoch)
    }
  }

  func setLineNumbers(_ on: Bool) async { await setOption(\.showLineNumbers, on) }
  func setTrackSizes(_ on: Bool) async { await setOption(\.showTrackSizes, on) }
  func setAreaNames(_ on: Bool) async { await setOption(\.showAreaNames, on) }

  func selectionLocked(_ id: Int?) {
    guard Self.shouldClear(pinned: pinnedLock, locked: id) else { return }
    Task { await disableAll() }
  }

  func disableAll() async {
    enabled.removeAll()
    pinnedLock = nil
    showLineNumbers = true
    showTrackSizes = true
    showAreaNames = false
    failure = nil
    let generation = inspector?.documentGeneration ?? -1
    await enqueue(generation: generation) {
      await self.push(generation: generation, stamp: self.epoch)
    }
  }

  func reset() {
    epoch += 1
    tail?.cancel()
    tail = nil
    containers = []
    enabled.removeAll()
    pinnedLock = nil
    showLineNumbers = true
    showTrackSizes = true
    showAreaNames = false
    applied = false
    installedGeneration = -1
    failure = nil
  }

  func nodeID(for key: String) async throws -> Int? {
    guard let inspector else { return nil }
    let encoded = try JSONEncoder().encode(key)
    guard let literal = String(data: encoded, encoding: .utf8) else { return nil }
    let group = "shaar-inspector-layout-\(UUID().uuidString)"
    let destination = inspector.target
    defer { inspector.releaseGroup(group, target: destination) }
    let expression =
      "globalThis.__shaarInspectorLayout&&globalThis.__shaarInspectorLayout.node(\(literal))"
    let result = try await inspector.call(
      "Runtime.evaluate", params: ["expression": expression, "objectGroup": group])
    if result["exceptionDetails"] != nil { return nil }
    guard let objectID = (result["result"] as? [String: Any])?["objectId"] as? String else {
      return nil
    }
    return try await inspector.call("DOM.requestNode", params: ["objectId": objectID])["nodeId"]
      as? Int
  }

  private func setOption(_ path: ReferenceWritableKeyPath<InspectorLayoutModel, Bool>, _ on: Bool)
    async
  {
    self[keyPath: path] = on
    guard !enabled.isEmpty, let inspector else { return }
    let generation = inspector.documentGeneration
    await enqueue(generation: generation) {
      await self.push(generation: generation, stamp: self.epoch)
    }
  }

  private func enqueue(generation: Int, _ body: @escaping () async -> Void) async {
    let stamp = epoch
    let prior = tail
    let task = Task { @MainActor in
      _ = await prior?.value
      guard self.epoch == stamp, self.inspector?.documentGeneration == generation,
        self.inspector?.isOpen == true
      else { return }
      await body()
    }
    tail = task
    await task.value
  }

  private func push(generation: Int, stamp: Int) async {
    guard let inspector else { return }
    if enabled.isEmpty && !applied { return }
    do {
      var grids: [[String: Any]] = []
      var flexes: [[String: Any]] = []
      var missing: [String] = []
      for key in enabled.sorted() {
        guard live(generation: generation, stamp: stamp) else { throw CancellationError() }
        guard let node = try await nodeID(for: key) else {
          missing.append(key)
          continue
        }
        if containerKind(key) == .grid {
          grids.append([
            "nodeId": node,
            "gridHighlightConfig": Self.gridHighlightConfig(
              lineNumbers: showLineNumbers, trackSizes: showTrackSizes, areaNames: showAreaNames),
          ])
        } else if containerKind(key) == .flex {
          flexes.append([
            "nodeId": node,
            "flexContainerHighlightConfig": Self.flexHighlightConfig(),
          ])
        } else {
          missing.append(key)
        }
      }
      for key in missing { enabled.remove(key) }
      guard live(generation: generation, stamp: stamp) else { throw CancellationError() }
      if enabled.isEmpty && !applied { return }
      _ = try await inspector.call("Overlay.enable")
      guard live(generation: generation, stamp: stamp) else { throw CancellationError() }
      _ = try await inspector.call(
        "Overlay.setShowGridOverlays", params: ["gridNodeHighlightConfigs": grids])
      guard live(generation: generation, stamp: stamp) else { throw CancellationError() }
      _ = try await inspector.call(
        "Overlay.setShowFlexOverlays", params: ["flexNodeHighlightConfigs": flexes])
      guard live(generation: generation, stamp: stamp) else { throw CancellationError() }
      applied = !enabled.isEmpty
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      if unavailable(error) { return }
      noteFailure(generation: generation, stamp: stamp)
    }
  }

  private func containerKind(_ key: String) -> InspectorLayoutContainer.Kind? {
    containers.first { $0.key == key }?.kind
  }

  private func lockedSelectionID() -> Int? {
    guard let selection = inspector?.selection, selection.locked else { return nil }
    return selection.id
  }

  private func live(generation: Int, stamp: Int) -> Bool {
    guard let inspector, inspector.isOpen, inspector.documentGeneration == generation else {
      return false
    }
    return epoch == stamp
  }

  private func install(generation: Int) async throws {
    guard installedGeneration != generation else { return }
    _ = try await inspector?.evaluate(Self.install)
    installedGeneration = generation
  }

  private func noteFailure(generation: Int, stamp: Int) {
    guard live(generation: generation, stamp: stamp) else { return }
    failure = InspectorL10n.string("The page could not complete the Inspector request.")
  }

  private func unavailable(_ error: Error) -> Bool {
    error.localizedDescription == "This Inspector target is no longer available."
  }

  static let install = #"""
    (() => {
      if (globalThis.__shaarInspectorLayout) return true;
      const nodes = new Map();
      const clip = (value, limit) => String(value || '').slice(0, limit);
      const segment = (el) => {
        const name = el.localName || 'element';
        const parent = el.parentElement;
        if (!parent) return name;
        let count = 0;
        let index = 0;
        for (const child of parent.children) {
          if (child.localName !== el.localName) continue;
          count += 1;
          if (child === el) index = count;
        }
        if (count < 2) return name;
        return name + ':nth-of-type(' + index + ')';
      };
      const keyFor = (el) => {
        if (el.id) {
          const id = String(el.id);
          if (id.length <= 80) return '#' + id;
          let hash = 2166136261;
          for (let i = 0; i < id.length; i++) {
            hash ^= id.charCodeAt(i);
            hash = Math.imul(hash, 16777619);
          }
          return '#' + clip(id, 64) + '~' + (hash >>> 0).toString(36);
        }
        const parts = [];
        let current = el;
        while (current && current.nodeType === 1 && parts.length < 6) {
          parts.unshift(segment(current));
          current = current.parentElement;
        }
        return clip(parts.join('>'), 180);
      };
      const kindFor = (el) => {
        const display = getComputedStyle(el).display;
        if (display === 'grid' || display === 'inline-grid') return 'grid';
        if (display === 'flex' || display === 'inline-flex') return 'flex';
        return '';
      };
      const classesFor = (el) => {
        const names = [];
        for (const name of el.classList || []) {
          if (names.length >= 4) break;
          names.push(clip(name, 24));
        }
        return names;
      };
      const visit = (doc, depth, out) => {
        if (!doc || depth > 8 || out.length >= 40) return;
        const root = doc.body || doc.documentElement;
        if (!root) return;
        const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
        let el = walker.currentNode;
        while (el && out.length < 40) {
          if (el.nodeType === 1 && !(el.closest && el.closest('[data-shaar-inspector]'))) {
            const kind = kindFor(el);
            if (kind) {
              const base = keyFor(el);
              let key = base;
              let suffix = 1;
              while (nodes.has(key) && nodes.get(key) !== el) {
                key = clip(base, 174) + '~' + (++suffix);
              }
              if (!nodes.has(key)) {
                nodes.set(key, el);
                out.push({
                  key,
                  tag: clip(el.localName || 'element', 32),
                  id: clip(el.id || '', 80),
                  classes: classesFor(el),
                  kind
                });
              }
            }
          }
          el = walker.nextNode();
        }
        for (const frame of doc.querySelectorAll('iframe,frame')) {
          if (out.length >= 40) return;
          try { visit(frame.contentDocument, depth + 1, out); } catch {}
        }
      };
      globalThis.__shaarInspectorLayout = {
        read() {
          nodes.clear();
          const out = [];
          visit(document, 0, out);
          return out;
        },
        node(key) { return nodes.get(key) || null; }
      };
      return true;
    })()
    """#
}
