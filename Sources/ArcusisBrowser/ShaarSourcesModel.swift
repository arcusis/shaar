// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
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
  private(set) var sourceLoading = false
  private(set) var localFiles: [InspectorSourceLocation] = []
  private(set) var localRoot: String?
  var sourceFailure: String?
  var failure: String?
  var search = ""
  var prettyPrint = false {
    didSet { if prettyPrint != oldValue { sourcePage = 0 } }
  }
  private(set) var sourcePage = 0
  static let linesPerPage = 500
  @ObservationIgnored private let phase2: ShaarPhase2Model
  @ObservationIgnored private let loadSourceData: @Sendable (URL) async throws -> Data
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var contentRevision = 0
  @ObservationIgnored private var lineCache: (revision: Int, pretty: Bool, lines: [Substring])?

  init(
    phase2: ShaarPhase2Model,
    loadSourceData: @escaping @Sendable (URL) async throws -> Data = DevelopmentSourceHTTP.load
  ) {
    self.phase2 = phase2
    self.loadSourceData = loadSourceData
  }

  var selected: ShaarSourceResource? {
    resources.first { $0.url == selectedURL }
  }
  var isDevelopmentPage: Bool {
    DevelopmentPage.detect(url: phase2.target.url).isDevelopmentPage
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
    guard prettyPrint, isJSON else { return content }
    return Self.prettyJSON(content) ?? content
  }

  var displayedLines: [Substring]? {
    if let cache = lineCache, cache.revision == contentRevision,
      cache.pretty == prettyPrint
    {
      return cache.lines
    }
    guard let displayedContent else { return nil }
    let lines = displayedContent.split(separator: "\n", omittingEmptySubsequences: false)
    lineCache = (contentRevision, prettyPrint, lines)
    return lines
  }

  var sourcePageCount: Int {
    guard let count = displayedLines?.count else { return 0 }
    return max(1, (count + Self.linesPerPage - 1) / Self.linesPerPage)
  }

  var visibleLineRange: Range<Int> {
    guard let count = displayedLines?.count else { return 0..<0 }
    let start = min(sourcePage * Self.linesPerPage, count)
    return start..<min(start + Self.linesPerPage, count)
  }

  func showNextSourcePage() {
    if sourcePage + 1 < sourcePageCount { sourcePage += 1 }
  }

  func showPreviousSourcePage() {
    if sourcePage > 0 { sourcePage -= 1 }
  }

  var isJSON: Bool {
    selected?.mimeType.contains("json") == true || selected?.url.hasSuffix(".json") == true
  }

  func reset() {
    generation += 1
    contentRevision += 1
    lineCache = nil
    resources.removeAll()
    selectedURL = nil
    content = nil
    binary = false
    listTruncated = false
    contentTruncated = false
    loading = false
    contentLoading = false
    sourceLoading = false
    localFiles = []
    localRoot = nil
    sourceFailure = nil
    failure = nil
    search = ""
    prettyPrint = false
    sourcePage = 0
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
    sourcePage = 0
    content = nil
    contentRevision += 1
    lineCache = nil
    binary = false
    contentTruncated = false
    localFiles = []
    localRoot = nil
    sourceFailure = nil
    await loadSelected()
  }

  func findLocalFiles(framework: DevelopmentFramework?, workspaceRootOverride: String? = nil) async
  {
    guard !sourceLoading else { return }
    guard let selected, let resourceURL = URL(string: selected.url),
      DevelopmentPage.detect(url: phase2.target.url).isDevelopmentPage,
      DevelopmentSourceResolver.sameOrigin(resourceURL, phase2.target.url),
      let workspaceURL = DevelopmentSourceResolver.workspaceURL(for: phase2.target.url)
    else {
      sourceFailure = ShellL10n.string("Local files are available for development pages only")
      return
    }
    let selection = selected.url
    let generation = generation
    sourceLoading = true
    sourceFailure = nil
    localFiles = []
    defer { if generation == self.generation { sourceLoading = false } }
    do {
      let root: String
      if let workspaceRootOverride {
        root = workspaceRootOverride
      } else {
        let metadata = try await loadSourceData(workspaceURL)
        guard generation == self.generation, selectedURL == selection else { return }
        guard let providedRoot = DevelopmentSourceResolver.workspaceRoot(from: metadata) else {
          sourceFailure = ShellL10n.string("The development server did not provide a project root")
          return
        }
        root = providedRoot
      }
      let mapURL = content.flatMap {
        DevelopmentSourceResolver.sourceMapURL(in: $0, resourceURL: resourceURL)
      }
      var sourceMap: Data?
      if let mapURL { sourceMap = try await loadSourceData(mapURL) }
      guard generation == self.generation, selectedURL == selection else { return }
      localFiles = DevelopmentSourceResolver.locations(
        resourceURL: resourceURL, workspaceRoot: root, framework: framework,
        sourceMap: sourceMap)
      localRoot = root
      if localFiles.isEmpty {
        sourceFailure = ShellL10n.string("No matching local files were found")
      }
    } catch {
      if generation == self.generation, selectedURL == selection {
        sourceFailure = ShellL10n.string("Local source files could not be loaded")
      }
    }
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
    sourcePage = 0
    content = nil
    contentRevision += 1
    lineCache = nil
    contentTruncated = false
    defer {
      if generation == self.generation, selectedURL == url { contentLoading = false }
    }
    do {
      let reply = try await phase2.execute(.resourceContent(url: url))
      guard generation == self.generation, selectedURL == url else { return }
      content = reply.body
      contentRevision += 1
      binary = reply.base64Encoded == true
      contentTruncated = reply.truncated
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
