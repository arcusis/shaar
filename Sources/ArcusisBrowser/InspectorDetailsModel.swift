// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct InspectorComponentTree: Codable {
  struct Entry: Codable, Identifiable {
    let id: Int
    let name: String
    let parent: Int?
    let source: String?
  }
  let framework: String?
  let nodes: [Entry]
  let selected: Int?
  let limit: String?
}

struct InspectorComponentData: Codable {
  let id: Int
  let name: String
  let source: String?
  let props: String
  let state: String
  let hooks: String
  let truncated: Bool
  let note: String?
}

struct InspectorAccessibilityData: Decodable {
  let aria: [Property]
  let tabOrder: Int?
  let tabLimit: Bool
  var warnings: [String]
  struct Property: Decodable, Identifiable {
    let name: String
    let value: String
    var id: String { name }
  }
  var role = "Unavailable"
  var name = ""
  var ignored: Bool?
  var properties: [Property] = []
  enum CodingKeys: CodingKey { case aria, tabOrder, tabLimit, warnings }
}

struct InspectorAssetsData: Decodable {
  struct Image: Decodable, Identifiable {
    let index: Int
    let url: String
    let renderedWidth: Double
    let renderedHeight: Double
    let naturalWidth: Double
    let naturalHeight: Double
    let transferSize: Double?
    let bodySize: Double?
    var mime: String?
    var frameID: String?
    var id: String { "\(index)|\(url)" }
    var valid: Bool {
      (0..<16).contains(index) && url.count <= 16_384
        && [renderedWidth, renderedHeight, naturalWidth, naturalHeight].allSatisfy {
          $0.isFinite && $0 >= 0 && $0 <= 1_000_000
        } && [transferSize, bodySize].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
    }
  }
  struct Font: Identifiable {
    let url: String
    let mime: String
    let frameID: String
    var id: String { url }
  }
  let images: [Image]
  let svg: String?
  let svgTruncated: Bool
  var fonts: [Font] = []
  enum CodingKeys: CodingKey { case images, svg, svgTruncated }
}

@MainActor @Observable
final class InspectorDetailsModel {
  @ObservationIgnored weak var inspector: InspectorModel?
  private(set) var tree: InspectorComponentTree?
  private(set) var component: InspectorComponentData?
  private(set) var accessibility: InspectorAccessibilityData?
  private(set) var assets: InspectorAssetsData?
  private(set) var selectedID: Int?
  private(set) var activeTab = InspectorModel.Tab.component
  private(set) var failure: String?
  private(set) var busy = false
  private(set) var selectedComponent: Int?
  @ObservationIgnored private var epoch = -1
  @ObservationIgnored private var updated = Date.distantPast
  @ObservationIgnored private var componentRequest = 0

  init(inspector: InspectorModel) { self.inspector = inspector }

  func reset() {
    componentRequest += 1
    tree = nil
    component = nil
    accessibility = nil
    assets = nil
    selectedID = nil
    selectedComponent = nil
    failure = nil
    updated = .distantPast
  }

  func refresh(force: Bool = false) async {
    if force {
      while busy && inspector?.isOpen == true && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }
    guard !busy, !Task.isCancelled, let inspector, inspector.isOpen,
      let selection = inspector.selection, selection.locked,
      [.component, .accessibility, .assets].contains(inspector.tab)
    else { return }
    let generation = inspector.documentGeneration
    let tab = inspector.tab
    let changed = selectedID != selection.id || epoch != generation || tab != activeTab
    guard force || changed || Date().timeIntervalSince(updated) > 1 else { return }
    busy = true
    defer { busy = false }
    do {
      switch tab {
      case .component:
        let next: InspectorComponentTree = try await packet("components()", inspector: inspector)
        let identities = Set(next.nodes.map(\.id))
        guard next.framework == nil || ["React", "Vue", "Svelte"].contains(next.framework!),
          next.nodes.count <= 250, identities.count == next.nodes.count,
          next.nodes.allSatisfy({ $0.parent == nil || identities.contains($0.parent!) }),
          next.selected == nil || identities.contains(next.selected!),
          next.nodes.allSatisfy({
            $0.id > 0 && $0.name.count <= 160 && ($0.source?.count ?? 0) <= 1024
          }), (next.limit?.count ?? 0) <= 512
        else { throw InspectorFailure("Component tree exceeds supported limits.") }
        let chosen =
          !changed && next.nodes.contains(where: { $0.id == selectedComponent })
          ? selectedComponent : next.selected
        let data: InspectorComponentData? =
          if let chosen { try await packet("componentData(\(chosen))", inspector: inspector) } else
          { nil }
        guard matches(inspector, id: selection.id, generation: generation, tab: tab) else { return }
        if !changed && selectedComponent != chosen { return }
        try validate(data)
        guard data?.id == chosen else { throw CancellationError() }
        tree = next
        component = data
        selectedComponent = chosen
      case .accessibility:
        var next: InspectorAccessibilityData = try await packet(
          "accessibility()", inspector: inspector)
        guard next.aria.count <= 64,
          next.aria.allSatisfy({ $0.name.count <= 128 && $0.value.count <= 512 }),
          next.warnings.count <= 16, next.warnings.allSatisfy({ $0.count <= 512 }),
          next.tabOrder.map({ (1...5000).contains($0) }) ?? true
        else { throw InspectorFailure("Accessibility data exceeds supported limits.") }
        let result = try await inspector.withSelectedNode { node in
          let description = try await inspector.call("DOM.describeNode", params: ["nodeId": node])
          let tree = try await inspector.call(
            "Accessibility.getPartialAXTree", params: ["nodeId": node, "fetchRelatives": false])
          return (description, tree)
        }
        let backend = (result.0["node"] as? [String: Any])?["backendNodeId"] as? Int
        if let backend,
          let node = (result.1["nodes"] as? [[String: Any]])?.first(where: {
            ($0["backendDOMNodeId"] as? Int) == backend
          })
        {
          next.role = axValue(node["role"]) ?? "Unavailable"
          next.name = axValue(node["name"]) ?? ""
          next.ignored = node["ignored"] as? Bool ?? false
          next.properties = ((node["properties"] as? [[String: Any]]) ?? []).prefix(64).compactMap {
            row in
            guard let name = row["name"] as? String, let value = axValue(row["value"]) else {
              return nil
            }
            return .init(name: String(name.prefix(128)), value: value)
          }
          if ["button", "link", "textbox", "checkbox", "radio", "combobox", "switch"].contains(
            next.role), next.name.isEmpty
          {
            next.warnings.append("Interactive element has no accessible name.")
          }
        }
        if selection.contrastGrade == "Fail" {
          next.warnings.append("Computed text contrast is below WCAG AA.")
        }
        guard matches(inspector, id: selection.id, generation: generation, tab: tab) else { return }
        accessibility = next
      case .assets:
        let next: InspectorAssetsData = try await packet("assets()", inspector: inspector)
        guard next.images.count <= 16, next.images.allSatisfy(\.valid),
          (next.svg?.utf8.count ?? 0) <= 262_144
        else { throw InspectorFailure("Asset data exceeds supported limits.") }
        let resources = try await resourceList(inspector)
        var images = next.images
        for index in images.indices {
          images[index].mime = nil
          images[index].frameID = nil
          if let resource = resources.first(where: { $0.url == images[index].url }) {
            images[index].mime = resource.mime
            images[index].frameID = resource.frameID
          }
        }
        var resolved = InspectorAssetsData(
          images: images, svg: next.svg, svgTruncated: next.svgTruncated)
        var seen = Set<String>()
        resolved.fonts = resources.filter { $0.kind == "Font" && seen.insert($0.url).inserted }
          .prefix(80).map {
            .init(url: $0.url, mime: $0.mime, frameID: $0.frameID)
          }
        guard matches(inspector, id: selection.id, generation: generation, tab: tab) else { return }
        assets = resolved
      default: return
      }
      selectedID = selection.id
      epoch = generation
      activeTab = tab
      updated = Date()
      failure = nil
    } catch {
      if matches(inspector, id: selection.id, generation: generation, tab: tab),
        !(error is CancellationError)
      {
        failure = error.localizedDescription
      }
    }
  }

  func selectComponent(_ identity: Int) async {
    guard let inspector, tree?.nodes.contains(where: { $0.id == identity }) == true,
      inspector.selection?.id == selectedID
    else { return }
    let generation = inspector.documentGeneration
    let element = selectedID
    componentRequest += 1
    let request = componentRequest
    selectedComponent = identity
    component = nil
    do {
      let next: InspectorComponentData = try await packet(
        "componentData(\(identity))", inspector: inspector)
      guard request == componentRequest,
        matches(inspector, id: element, generation: generation, tab: .component),
        next.id == identity
      else {
        return
      }
      try validate(next)
      selectedComponent = identity
      component = next
    } catch {
      if request == componentRequest,
        matches(inspector, id: element, generation: generation, tab: .component)
      {
        failure = error.localizedDescription
      }
    }
  }

  private func validate(_ value: InspectorComponentData?) throws {
    guard let value else { return }
    guard value.id > 0, value.name.count <= 160, (value.source?.count ?? 0) <= 1024,
      (value.note?.count ?? 0) <= 512,
      [value.props, value.state, value.hooks].allSatisfy({ $0.utf8.count <= 262_144 })
    else { throw InspectorFailure("Component values exceed supported limits.") }
  }

  private func matches(
    _ inspector: InspectorModel, id: Int?, generation: Int, tab: InspectorModel.Tab
  ) -> Bool {
    inspector.isOpen && inspector.documentGeneration == generation && inspector.selection?.id == id
      && inspector.tab == tab
  }

  private func packet<T: Decodable>(_ expression: String, inspector: InspectorModel) async throws
    -> T
  {
    guard
      let value = try await inspector.evaluate("globalThis.__shaarInspectorDetails.\(expression)")
    else { throw InspectorFailure("The selected element is no longer available.") }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    guard data.count <= 1_048_576 else {
      throw InspectorFailure("Element details exceed the supported size.")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func axValue(_ value: Any?) -> String? {
    guard let object = value as? [String: Any], let raw = object["value"] else { return nil }
    if let text = raw as? String { return String(text.prefix(512)) }
    guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return String(text.prefix(512))
  }

  private struct Resource {
    let url: String
    let mime: String
    let kind: String
    let frameID: String
  }
  private func resourceList(_ inspector: InspectorModel) async throws -> [Resource] {
    let result = try await inspector.call("Page.getResourceTree")
    var rows: [Resource] = []
    func walk(_ tree: [String: Any], depth: Int = 0) {
      guard depth < 8, rows.count < 1024, let frame = tree["frame"] as? [String: Any],
        let id = frame["id"] as? String
      else { return }
      for row in (tree["resources"] as? [[String: Any]] ?? []).prefix(1024) {
        guard let url = row["url"] as? String, url.count <= 16_384,
          let mime = row["mimeType"] as? String, let type = row["type"] as? String,
          ["Image", "Font"].contains(type), rows.count < 1024
        else { continue }
        rows.append(.init(url: url, mime: String(mime.prefix(128)), kind: type, frameID: id))
      }
      for child in (tree["childFrames"] as? [[String: Any]] ?? []).prefix(64) {
        walk(child, depth: depth + 1)
      }
    }
    if let tree = result["frameTree"] as? [String: Any] { walk(tree) }
    return rows
  }

  func resourceData(url: String, frameID: String) async throws -> Data {
    guard let inspector, inspector.isOpen,
      assets?.images.contains(where: { $0.url == url && $0.frameID == frameID }) == true
        || assets?.fonts.contains(where: { $0.url == url && $0.frameID == frameID }) == true
    else { throw InspectorFailure("This asset is no longer selected.") }
    let generation = inspector.documentGeneration
    let identity = selectedID
    let result = try await inspector.call(
      "Page.getResourceContent", params: ["url": url, "frameId": frameID])
    guard matches(inspector, id: identity, generation: generation, tab: .assets),
      let content = result["content"] as? String, content.utf8.count <= 44_739_244
    else { throw InspectorFailure("Asset data is unavailable or exceeds 32 MiB.") }
    if result["base64Encoded"] as? Bool == true, let data = Data(base64Encoded: content) {
      return data
    }
    if result["base64Encoded"] as? Bool == false { return Data(content.utf8) }
    throw InspectorFailure("Chromium did not return this resource's content.")
  }

  func saveAsset(url: String, frameID: String) async {
    do {
      let data = try await resourceData(url: url, frameID: frameID)
      let panel = NSSavePanel()
      let filename = (URL(string: url)?.lastPathComponent ?? "asset").unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0)
          ? "_" : String($0)
      }.joined()
      panel.nameFieldStringValue =
        filename.isEmpty || [".", ".."].contains(filename) ? "asset" : String(filename.prefix(160))
      guard await panel.begin() == .OK, let destination = panel.url else { return }
      try data.write(to: destination, options: .atomic)
    } catch { failure = error.localizedDescription }
  }
}
