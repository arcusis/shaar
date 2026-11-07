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
  typealias InspectorContent =
    @MainActor (String, SiteControlTarget) async throws -> (
      body: String, base64Encoded: Bool
    )
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
  var contentQuery = "" {
    didSet { if contentQuery != oldValue { matchCursor = 0 } }
  }
  var prettyPrint = false {
    didSet {
      if prettyPrint != oldValue {
        sourcePage = 0
        highlightedLine = nil
        matchCursor = 0
      }
    }
  }
  private(set) var sourcePage = 0
  private(set) var highlightedLine: Int?
  private(set) var matchCursor = 0
  static let linesPerPage = 500
  @ObservationIgnored private let phase2: ShaarPhase2Model
  @ObservationIgnored private let inspectorContent: InspectorContent?
  @ObservationIgnored private let loadSourceData: @Sendable (URL) async throws -> Data
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var contentRevision = 0
  @ObservationIgnored private var lineCache: (revision: Int, pretty: Bool, lines: [Substring])?

  init(
    phase2: ShaarPhase2Model,
    inspectorContent: InspectorContent? = nil,
    loadSourceData: @escaping @Sendable (URL) async throws -> Data = DevelopmentSourceHTTP.load
  ) {
    self.phase2 = phase2
    self.inspectorContent = inspectorContent
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

  var treeRows: [ShaarSourceTreeRow] { ShaarSourceTree.rows(for: visibleResources) }

  var displayedContent: String? {
    guard let content, !binary else { return nil }
    guard prettyPrint, let kind = prettyKind else { return content }
    return ShaarSourceFormatter.format(content, kind: kind)
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

  var isJSON: Bool { prettyKind == .json }
  var canPrettyPrint: Bool { prettyKind != nil }

  var prettyKind: ShaarSourceKind? {
    guard let selected else { return nil }
    let mime = selected.mimeType.lowercased()
    let name = selected.name.lowercased()
    if mime.contains("json") || name.hasSuffix(".json") { return .json }
    if mime.contains("javascript") || mime.contains("ecmascript") || name.hasSuffix(".js")
      || name.hasSuffix(".mjs")
    {
      return .script
    }
    if mime.contains("css") || name.hasSuffix(".css") { return .style }
    return nil
  }

  var matchLines: [Int] {
    let needle = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let lines = displayedLines, !needle.isEmpty else { return [] }
    return lines.indices.filter { lines[$0].localizedStandardContains(needle) }
  }

  func revealCurrentMatch() {
    let lines = matchLines
    guard lines.indices.contains(matchCursor) else {
      // An empty query is not a failed search. Keep a console jump highlight.
      if !contentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        highlightedLine = nil
      }
      return
    }
    showLine(lines[matchCursor])
  }

  func showNextContentMatch() { stepContentMatch(1) }
  func showPreviousContentMatch() { stepContentMatch(-1) }

  func reveal(url: String, line: Int) async -> Bool {
    if prettyPrint { prettyPrint = false }
    guard let resource = resources.first(where: { ShaarSourceTree.sameResource($0.url, url) })
    else {
      sourceFailure = ShellL10n.string("This stack frame is not in the loaded resources")
      return false
    }
    if selectedURL != resource.url {
      await select(resource)
    } else if content == nil {
      await loadSelected()
    }
    guard line >= 1 else { return false }
    let index = line - 1
    guard let lines = displayedLines else {
      sourceFailure = failure ?? ShellL10n.string("That line is outside the loaded source")
      return false
    }
    guard lines.indices.contains(index) else {
      sourceFailure = ShellL10n.string("That line is outside the loaded source")
      return false
    }
    sourceFailure = nil
    showLine(index)
    return true
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
    contentQuery = ""
    prettyPrint = false
    sourcePage = 0
    highlightedLine = nil
    matchCursor = 0
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
    highlightedLine = nil
    matchCursor = 0
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
    let visible = treeRows.compactMap(\.resourceURL)
    guard !visible.isEmpty else { return }
    let index = visible.firstIndex { $0 == selectedURL }
    let next =
      forward
      ? min(visible.count - 1, (index ?? -1) + 1)
      : max(0, (index ?? 1) - 1)
    guard let resource = resources.first(where: { $0.url == visible[next] }) else { return }
    await select(resource)
  }

  /// Text resources sometimes arrive base64-encoded. Images stay binary.
  private static func readableText(body: String?, base64Encoded: Bool) -> (
    body: String?, binary: Bool
  ) {
    guard base64Encoded, let body, let data = Data(base64Encoded: body),
      let text = String(data: data, encoding: .utf8)
    else { return (body, base64Encoded) }
    return (text, false)
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
      let loaded = try await loadResourceText(url: url)
      guard generation == self.generation, selectedURL == url else { return }
      content = loaded.body
      contentRevision += 1
      binary = loaded.base64Encoded
      contentTruncated = loaded.truncated
      failure = nil
    } catch is CancellationError {
      return
    } catch {
      if generation == self.generation, selectedURL == url {
        failure = error.localizedDescription
      }
    }
  }

  func loadStylesheets() async throws -> ShaarLoadedStylesheets? {
    guard phase2.available else { return nil }
    let reply = try await phase2.execute(.resourceTree)
    var resources: [ShaarSourceResource] = []
    for item in reply.items {
      guard let url = item.text["url"] else { continue }
      let type = item.text["type"] ?? ""
      let mimeType = item.text["mimeType"] ?? ""
      guard ShaarDevToolsCSSOverview.isStylesheet(type: type, mimeType: mimeType, url: url),
        ShaarDevToolsCSSOverview.isLoadableSheetURL(url)
      else { continue }
      resources.append(ShaarSourceResource(url: url, type: type, mimeType: mimeType))
    }
    var sheets: [ShaarDevToolsCSSSheet] = []
    var clipped = resources.count > ShaarDevToolsCSSOverview.maximumSheets
    for resource in resources.prefix(ShaarDevToolsCSSOverview.maximumSheets) {
      let loaded = try await loadResourceText(url: resource.url)
      if loaded.base64Encoded { continue }
      let piece = ShaarDevToolsCSSOverview.clipped(loaded.body ?? "")
      if piece.clipped { clipped = true }
      sheets.append(ShaarDevToolsCSSSheet(name: resource.name, url: resource.url, text: piece.text))
    }
    return ShaarLoadedStylesheets(sheets: sheets, clipped: clipped)
  }

  private struct LoadedResourceText {
    var body: String?
    var base64Encoded: Bool
    var truncated: Bool
  }

  private func loadResourceText(url: String) async throws -> LoadedResourceText {
    do {
      let reply = try await phase2.execute(.resourceContent(url: url))
      let decoded = Self.readableText(body: reply.body, base64Encoded: reply.base64Encoded == true)
      return LoadedResourceText(
        body: decoded.body, base64Encoded: decoded.binary, truncated: reply.truncated)
    } catch {
      guard !(error is CancellationError), let inspectorContent,
        let resourceURL = URL(string: url),
        DevelopmentSourceResolver.sameOrigin(resourceURL, phase2.target.url)
      else { throw error }
      let fallback = try await inspectorContent(url, phase2.target)
      let decoded = Self.readableText(
        body: fallback.body, base64Encoded: fallback.base64Encoded)
      return LoadedResourceText(
        body: decoded.body, base64Encoded: decoded.binary, truncated: false)
    }
  }

  private func stepContentMatch(_ delta: Int) {
    let lines = matchLines
    guard !lines.isEmpty else { return }
    matchCursor = (matchCursor + delta + lines.count) % lines.count
    showLine(lines[matchCursor])
  }

  private func showLine(_ line: Int) {
    highlightedLine = line
    let page = line / Self.linesPerPage
    if page != sourcePage { sourcePage = page }
  }
}
