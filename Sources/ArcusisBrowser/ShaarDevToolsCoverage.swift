// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum ShaarDevToolsCoverageKind: String, Equatable, Sendable {
  case script
  case stylesheet

  var title: String {
    switch self {
    case .script: "Script"
    case .stylesheet: "Style sheet"
    }
  }
}

struct ShaarDevToolsCoverageSpan: Equatable, Sendable {
  var start: Int
  var end: Int
}

struct ShaarDevToolsCoverageCountedSpan: Equatable, Sendable {
  var start: Int
  var end: Int
  var count: Int
}

struct ShaarDevToolsCoverageScript: Equatable, Sendable {
  var url: String
  var ranges: [ShaarDevToolsCoverageCountedSpan]
}

struct ShaarDevToolsCoverageSheet: Equatable, Sendable {
  var url: String
  var totalBytes: Int
  var usedRanges: [ShaarDevToolsCoverageSpan]
}

struct ShaarDevToolsCoverageRow: Equatable, Identifiable, Sendable {
  var id: String
  var url: String
  var kind: ShaarDevToolsCoverageKind
  var usedBytes: Int
  var totalBytes: Int
  var unusedBytes: Int
  var percent: Int
}

enum ShaarCoverageNotice: Equatable {
  case needsPage
  case failed(String)
}

struct ShaarCoverageFailure: LocalizedError {
  var errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

@MainActor protocol ShaarCoverageTransport {
  func execute(_ method: String) async -> [String: Any]
}

enum ShaarDevToolsCoverage {
  static func summarize(
    scripts: [ShaarDevToolsCoverageScript], sheets: [ShaarDevToolsCoverageSheet]
  ) -> [ShaarDevToolsCoverageRow] {
    var rows: [ShaarDevToolsCoverageRow] = []
    for script in scripts {
      let total = scriptTotal(script)
      let used = usedByteCount(total: total, ranges: usedSpans(in: script))
      rows.append(row(url: script.url, kind: .script, used: used, total: total))
    }
    for sheet in sheets {
      let total = max(0, sheet.totalBytes)
      let used = usedByteCount(total: total, ranges: sheet.usedRanges)
      rows.append(row(url: sheet.url, kind: .stylesheet, used: used, total: total))
    }
    return rows.sorted(by: unusedFirst)
  }

  static func scripts(from reply: [String: Any]) -> [ShaarDevToolsCoverageScript] {
    let result = reply["result"] as? [[String: Any]] ?? []
    var scripts: [ShaarDevToolsCoverageScript] = []
    for (index, item) in result.enumerated() {
      let url = scriptURL(item, index: index)
      var ranges: [ShaarDevToolsCoverageCountedSpan] = []
      let functions = item["functions"] as? [[String: Any]] ?? []
      for function in functions {
        let listed = function["ranges"] as? [[String: Any]] ?? []
        for range in listed {
          ranges.append(countedSpan(range))
        }
      }
      scripts.append(ShaarDevToolsCoverageScript(url: url, ranges: ranges))
    }
    return scripts
  }

  static func sheets(from reply: [String: Any]) -> [ShaarDevToolsCoverageSheet] {
    if let listed = reply["sheets"] as? [[String: Any]] {
      return listed.compactMap(sheet(from:))
    }
    return groupedSheets(reply["ruleUsage"] as? [[String: Any]] ?? [])
  }

  static func usedByteCount(total: Int, ranges: [ShaarDevToolsCoverageSpan]) -> Int {
    let limit = max(0, total)
    let clamped = ranges.compactMap { clampedSpan($0, limit: limit) }
    let ordered = clamped.sorted { $0.start < $1.start }
    let merged = mergedSpans(ordered)
    return merged.reduce(0) { $0 + ($1.end - $1.start) }
  }

  static func percent(used: Int, total: Int) -> Int {
    guard total > 0 else { return 0 }
    return min(used, total) * 100 / total
  }

  static func sizeLabel(_ bytes: Int) -> String {
    if bytes < 1_024 { return "\(bytes) B" }
    return String(format: "%.1f KB", Double(bytes) / 1_024)
  }

  static func displayName(_ url: String) -> String {
    guard let parsed = URL(string: url), parsed.host != nil else { return url }
    if parsed.path.isEmpty || parsed.path == "/" { return parsed.host ?? url }
    return parsed.path
  }

  private static func scriptTotal(_ script: ShaarDevToolsCoverageScript) -> Int {
    script.ranges.reduce(0) { partial, range in
      max(partial, range.end)
    }
  }

  private static func usedSpans(
    in script: ShaarDevToolsCoverageScript
  ) -> [ShaarDevToolsCoverageSpan] {
    script.ranges.compactMap { range in
      guard range.count > 0 else { return nil }
      return ShaarDevToolsCoverageSpan(start: range.start, end: range.end)
    }
  }

  private static func row(
    url: String, kind: ShaarDevToolsCoverageKind, used: Int, total: Int
  ) -> ShaarDevToolsCoverageRow {
    let safeTotal = max(0, total)
    let safeUsed = min(safeTotal, max(0, used))
    return ShaarDevToolsCoverageRow(
      id: "\(kind.rawValue):\(url)",
      url: url,
      kind: kind,
      usedBytes: safeUsed,
      totalBytes: safeTotal,
      unusedBytes: safeTotal - safeUsed,
      percent: percent(used: safeUsed, total: safeTotal))
  }

  private static func unusedFirst(
    _ lhs: ShaarDevToolsCoverageRow, _ rhs: ShaarDevToolsCoverageRow
  ) -> Bool {
    if lhs.unusedBytes != rhs.unusedBytes { return lhs.unusedBytes > rhs.unusedBytes }
    return lhs.url < rhs.url
  }

  private static func scriptURL(_ item: [String: Any], index: Int) -> String {
    if let url = item["url"] as? String, !url.isEmpty { return url }
    if let scriptID = item["scriptId"] as? String, !scriptID.isEmpty {
      return "script \(scriptID)"
    }
    return "script \(index + 1)"
  }

  private static func countedSpan(_ range: [String: Any]) -> ShaarDevToolsCoverageCountedSpan {
    let start = integer(range["startOffset"]) ?? 0
    let end = integer(range["endOffset"]) ?? start
    let count = integer(range["count"]) ?? 0
    return ShaarDevToolsCoverageCountedSpan(start: start, end: end, count: count)
  }

  private static func sheet(from item: [String: Any]) -> ShaarDevToolsCoverageSheet? {
    guard let url = item["url"] as? String, !url.isEmpty else { return nil }
    let rules = item["ruleUsage"] as? [[String: Any]] ?? []
    let total = integer(item["totalBytes"]) ?? spanEnd(of: rules)
    return ShaarDevToolsCoverageSheet(
      url: url, totalBytes: max(0, total), usedRanges: usedRanges(in: rules))
  }

  private static func groupedSheets(_ rules: [[String: Any]]) -> [ShaarDevToolsCoverageSheet] {
    var order: [String] = []
    var groups: [String: [[String: Any]]] = [:]
    for rule in rules {
      let key = sheetKey(rule)
      guard !key.isEmpty else { continue }
      if groups[key] == nil { order.append(key) }
      appendRule(rule, to: &groups, key: key)
    }
    return order.compactMap { key in
      guard let rules = groups[key] else { return nil }
      return ShaarDevToolsCoverageSheet(
        url: key, totalBytes: spanEnd(of: rules), usedRanges: usedRanges(in: rules))
    }
  }

  private static func sheetKey(_ rule: [String: Any]) -> String {
    if let url = rule["url"] as? String, !url.isEmpty { return url }
    if let identifier = rule["styleSheetId"] as? String { return identifier }
    return ""
  }

  private static func appendRule(
    _ rule: [String: Any], to groups: inout [String: [[String: Any]]], key: String
  ) {
    var list = groups[key] ?? []
    list.append(rule)
    groups[key] = list
  }

  private static func spanEnd(of rules: [[String: Any]]) -> Int {
    rules.reduce(0) { partial, rule in
      max(partial, integer(rule["endOffset"]) ?? 0)
    }
  }

  private static func usedRanges(in rules: [[String: Any]]) -> [ShaarDevToolsCoverageSpan] {
    rules.compactMap { rule in
      guard bool(rule["used"]) == true else { return nil }
      let start = integer(rule["startOffset"]) ?? 0
      let end = integer(rule["endOffset"]) ?? start
      return ShaarDevToolsCoverageSpan(start: start, end: end)
    }
  }

  private static func clampedSpan(
    _ span: ShaarDevToolsCoverageSpan, limit: Int
  ) -> ShaarDevToolsCoverageSpan? {
    let start = min(limit, max(0, span.start))
    let end = min(limit, max(start, span.end))
    guard end > start else { return nil }
    return ShaarDevToolsCoverageSpan(start: start, end: end)
  }

  private static func mergedSpans(
    _ ordered: [ShaarDevToolsCoverageSpan]
  ) -> [ShaarDevToolsCoverageSpan] {
    var merged: [ShaarDevToolsCoverageSpan] = []
    for span in ordered {
      guard let last = merged.last else {
        merged.append(span)
        continue
      }
      if span.start <= last.end {
        let combined = ShaarDevToolsCoverageSpan(start: last.start, end: max(last.end, span.end))
        merged[merged.count - 1] = combined
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? Double { return Int(value) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
  }
}

@MainActor @Observable final class ShaarDevToolsCoverageModel {
  private(set) var rows: [ShaarDevToolsCoverageRow] = []
  private(set) var recording = false
  private(set) var notice: ShaarCoverageNotice?
  /// Turns on after the page accepts the coverage commands. Stays off when the engine rejects them.
  var collectionReady = false
  @ObservationIgnored var transport: (any ShaarCoverageTransport)?
  @ObservationIgnored var send: (@MainActor (String, [String: Any]) async throws -> [String: Any])?
  @ObservationIgnored private weak var engine: BrowserEngine?
  @ObservationIgnored private var target: SiteControlTarget?
  @ObservationIgnored private var probeFinished = false
  @ObservationIgnored private var probeInFlight = false

  func present(
    scripts: [ShaarDevToolsCoverageScript], sheets: [ShaarDevToolsCoverageSheet]
  ) {
    rows = ShaarDevToolsCoverage.summarize(scripts: scripts, sheets: sheets)
    notice = nil
  }

  func recordFixture() async {
    guard let transport else { return }
    _ = await transport.execute("Profiler.startPreciseCoverage")
    let taken = await transport.execute("Profiler.takePreciseCoverage")
    _ = await transport.execute("Profiler.stopPreciseCoverage")
    _ = await transport.execute("CSS.startRuleUsageTracking")
    let rules = await transport.execute("CSS.stopRuleUsageTracking")
    rows = ShaarDevToolsCoverage.summarize(
      scripts: ShaarDevToolsCoverage.scripts(from: taken),
      sheets: ShaarDevToolsCoverage.sheets(from: rules))
    notice = nil
  }

  func attach(_ inspector: InspectorModel, target: SiteControlTarget) {
    engine = inspector.engine
    self.target = target
    guard engine != nil else {
      send = nil
      return
    }
    send = { [weak self] method, params in
      guard let self, let engine = self.engine, let target = self.target else {
        throw ShaarCoverageFailure(ShellL10n.string("Coverage needs a page to record."))
      }
      let page = engine.developerModel(for: target)
      try page.retainDeveloperSession()
      return try await page.call(method, params: params)
    }
  }

  /// Asks the page once. Start stays disabled only when the engine rejects the commands.
  func probeCollection() async {
    guard !probeFinished, !probeInFlight else { return }
    guard let send else { return }
    probeInFlight = true
    defer { probeInFlight = false }
    do {
      try await probePair(
        send,
        start: "Profiler.startPreciseCoverage",
        startParams: ["callCount": false, "detailed": false],
        stop: "Profiler.stopPreciseCoverage")
      _ = try await send("CSS.enable", [:])
      try await probePair(
        send,
        start: "CSS.startRuleUsageTracking",
        startParams: [:],
        stop: "CSS.stopRuleUsageTracking")
      collectionReady = true
      probeFinished = true
    } catch {
      if error is CancellationError || Task.isCancelled { return }
      if ShaarDevToolsSensorCapability.targetGone(error) { return }
      await stopProbeQuietly(send)
      collectionReady = !ShaarDevToolsSensorCapability.isMissing(error)
      probeFinished = true
    }
  }

  private func probePair(
    _ send: @MainActor (String, [String: Any]) async throws -> [String: Any],
    start: String,
    startParams: [String: Any],
    stop: String
  ) async throws {
    _ = try await send(start, startParams)
    _ = try? await send(stop, [:])
  }

  private func stopProbeQuietly(
    _ send: @MainActor (String, [String: Any]) async throws -> [String: Any]
  ) async {
    _ = try? await send("Profiler.stopPreciseCoverage", [:])
    _ = try? await send("CSS.stopRuleUsageTracking", [:])
  }

  func retarget(_ target: SiteControlTarget) {
    self.target = target
    reset()
  }

  func detach() {
    engine = nil
    send = nil
    reset()
    collectionReady = false
    probeFinished = false
    probeInFlight = false
  }

  func start() async {
    guard collectionReady, !recording else { return }
    guard let send else {
      notice = .needsPage
      return
    }
    recording = true
    notice = nil
    do {
      _ = try await send(
        "Profiler.startPreciseCoverage",
        ["callCount": false, "detailed": true] as [String: Any])
      _ = try await send("CSS.enable", [:])
      _ = try await send("CSS.startRuleUsageTracking", [:])
    } catch {
      recording = false
      notice = .failed(error.localizedDescription)
      await stopQuietly()
    }
  }

  func stop() async {
    guard collectionReady, recording else { return }
    guard let send else {
      recording = false
      notice = .needsPage
      return
    }
    do {
      let taken = try await send("Profiler.takePreciseCoverage", [:])
      _ = try await send("Profiler.stopPreciseCoverage", [:])
      let rules = try await send("CSS.stopRuleUsageTracking", [:])
      recording = false
      rows = ShaarDevToolsCoverage.summarize(
        scripts: ShaarDevToolsCoverage.scripts(from: taken),
        sheets: ShaarDevToolsCoverage.sheets(from: rules))
    } catch {
      recording = false
      notice = .failed(error.localizedDescription)
      await stopQuietly()
    }
  }

  func reset() {
    rows = []
    recording = false
    notice = nil
  }

  private func stopQuietly() async {
    guard let send else { return }
    _ = try? await send("Profiler.stopPreciseCoverage", [:])
    _ = try? await send("CSS.stopRuleUsageTracking", [:])
  }
}

struct ShaarDevToolsCoveragePanel: View {
  @Bindable var model: ShaarDevToolsCoverageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      controls
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("shaar.devtools.coverage")
    .task { await model.probeCollection() }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button(ShellL10n.string("Start")) {
          Task { await model.start() }
        }
        .controlSize(.small)
        .disabled(!model.collectionReady || model.recording)
        .accessibilityIdentifier("shaar.devtools.coverageStart")
        Button(ShellL10n.string("Stop")) {
          Task { await model.stop() }
        }
        .controlSize(.small)
        .disabled(!model.recording)
        .accessibilityIdentifier("shaar.devtools.coverageStop")
        Spacer(minLength: 0)
      }
      if !model.collectionReady {
        Text(ShellL10n.string("Coverage collection waits for the next engine build."))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("shaar.devtools.coverage.engineGate")
      }
      notice
    }
    .padding(12)
  }

  @ViewBuilder private var notice: some View {
    switch model.notice {
    case .needsPage:
      Text(ShellL10n.string("Coverage needs a page to record."))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    case .failed(let message):
      Text(verbatim: message)
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }

  @ViewBuilder private var content: some View {
    if model.rows.isEmpty {
      Text(ShellL10n.string("No coverage recorded for this tab."))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            ShaarDevToolsCoverageRowView(row: row, index: index)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct ShaarDevToolsCoverageRowView: View {
  var row: ShaarDevToolsCoverageRow
  var index: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(verbatim: ShaarDevToolsCoverage.displayName(row.url))
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(Text(verbatim: row.url))
        Spacer(minLength: 8)
        Text(ShellL10n.string(row.kind.title))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      UsageBar(fraction: fraction)
      Text(verbatim: summary)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("shaar.devtools.coverage.row.\(index)")
  }

  private var fraction: CGFloat {
    guard row.totalBytes > 0 else { return 0 }
    return CGFloat(row.usedBytes) / CGFloat(row.totalBytes)
  }

  private var summary: String {
    let used = ShaarDevToolsCoverage.sizeLabel(row.usedBytes)
    let total = ShaarDevToolsCoverage.sizeLabel(row.totalBytes)
    return "\(used) / \(total) · \(row.percent)%"
  }
}

private struct UsageBar: View {
  var fraction: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width * min(1, max(0, fraction))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.18))
        Capsule().fill(Color.accentColor).frame(width: width)
      }
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}
