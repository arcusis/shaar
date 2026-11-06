// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

struct ShaarSourceResource: Identifiable, Equatable {
  let url: String
  let type: String
  let mimeType: String
  var id: String { url }
  var name: String {
    guard let components = URLComponents(string: url) else { return url }
    let path = components.path
    if path == "/" || path.isEmpty { return components.host ?? url }
    return (path as NSString).lastPathComponent
  }
  var folder: String {
    guard let components = URLComponents(string: url) else { return "" }
    let parent = (components.path as NSString).deletingLastPathComponent
    return parent == "/" ? (components.host ?? "") : parent
  }
}

@MainActor @Observable
final class ShaarSourcesModel {
  private(set) var resources: [ShaarSourceResource] = []
  private(set) var selectedURL: String?
  private(set) var content: String?
  private(set) var binary = false
  private(set) var listTruncated = false
  private(set) var contentTruncated = false
  private(set) var loading = false
  private(set) var contentLoading = false
  var failure: String?
  var search = ""
  var prettyPrint = false
  @ObservationIgnored private let phase2: ShaarPhase2Model
  @ObservationIgnored private var generation = 0

  init(phase2: ShaarPhase2Model) { self.phase2 = phase2 }

  var selected: ShaarSourceResource? {
    resources.first { $0.url == selectedURL }
  }
  var truncated: Bool { listTruncated || contentTruncated }

  var visibleResources: [ShaarSourceResource] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return resources }
    return resources.filter {
      $0.name.localizedStandardContains(needle) || $0.url.localizedStandardContains(needle)
        || $0.type.localizedStandardContains(needle)
    }
  }

  var displayedContent: String? {
    guard let content, !binary else { return nil }
    let limited = String(content.prefix(262_144))
    guard prettyPrint, isJSON else { return limited }
    return Self.prettyJSON(limited) ?? limited
  }

  var isJSON: Bool {
    selected?.mimeType.contains("json") == true || selected?.url.hasSuffix(".json") == true
  }

  func reset() {
    generation += 1
    resources.removeAll()
    selectedURL = nil
    content = nil
    binary = false
    listTruncated = false
    contentTruncated = false
    loading = false
    contentLoading = false
    failure = nil
    search = ""
    prettyPrint = false
  }

  func refresh() async {
    guard phase2.available, !loading else { return }
    let generation = generation
    loading = true
    defer {
      if generation == self.generation { loading = false }
    }
    do {
      let reply = try await phase2.execute(.resourceTree)
      guard generation == self.generation else { return }
      resources = reply.items.compactMap { item in
        guard let url = item.text["url"] else { return nil }
        return ShaarSourceResource(
          url: url, type: item.text["type"] ?? "Other",
          mimeType: item.text["mimeType"] ?? "")
      }
      .sorted { $0.url.localizedStandardCompare($1.url) == .orderedAscending }
      if !resources.contains(where: { $0.url == selectedURL }) {
        selectedURL = resources.first?.url
      }
      listTruncated = reply.truncated || reply.hasMore == true
      failure = nil
      await loadSelected()
    } catch is CancellationError {
      return
    } catch {
      if generation == self.generation { failure = error.localizedDescription }
    }
  }

  func select(_ resource: ShaarSourceResource) async {
    guard resource.url != selectedURL else { return }
    selectedURL = resource.url
    content = nil
    binary = false
    contentTruncated = false
    await loadSelected()
  }

  func selectAdjacent(forward: Bool) async {
    let visible = visibleResources
    guard !visible.isEmpty else { return }
    let index = visible.firstIndex { $0.url == selectedURL }
    let next =
      forward
      ? min(visible.count - 1, (index ?? -1) + 1)
      : max(0, (index ?? 1) - 1)
    await select(visible[next])
  }

  private func loadSelected() async {
    guard let url = selectedURL, phase2.available else {
      content = nil
      return
    }
    let generation = generation
    contentLoading = true
    content = nil
    contentTruncated = false
    defer {
      if generation == self.generation, selectedURL == url { contentLoading = false }
    }
    do {
      let reply = try await phase2.execute(.resourceContent(url: url))
      guard generation == self.generation, selectedURL == url else { return }
      content = reply.body
      binary = reply.base64Encoded == true
      contentTruncated = reply.truncated || (reply.body?.count ?? 0) > 262_144
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      if generation == self.generation, selectedURL == url {
        failure = error.localizedDescription
      }
    }
  }

  private static func prettyJSON(_ value: String) -> String? {
    guard let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let formatted = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    else { return nil }
    return String(data: formatted, encoding: .utf8)
  }
}
