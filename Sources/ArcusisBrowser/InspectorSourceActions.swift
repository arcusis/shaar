// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Observation

struct InspectorSourceLocation: Equatable {
  let path: String
  let line: Int?
  let column: Int?

  static func parse(_ raw: String) -> Self? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= 1024, !value.contains("\n"), !value.contains("\r") else { return nil }
    let local = value.hasPrefix("file://") ? String(value.dropFirst(7)) : value
    let parts = local.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), let first = parts.first, first.hasPrefix("/"),
      !first.contains("\0"), !first.contains("?"), !first.contains("#"),
      parts.dropFirst().allSatisfy({ $0.count <= 7 && Int($0).map { $0 > 0 } == true })
    else { return nil }
    return .init(
      path: String(first), line: parts.count > 1 ? Int(parts[1]) : nil,
      column: parts.count > 2 ? Int(parts[2]) : nil)
  }

  func editorURL(_ editor: InspectorSourceEditor) -> URL? {
    guard editor != .showOnly else { return nil }
    if editor == .idea {
      var value = URLComponents()
      value.scheme = "idea"
      value.host = "open"
      value.queryItems = [URLQueryItem(name: "file", value: path)]
      if let line { value.queryItems?.append(.init(name: "line", value: String(line))) }
      if let column { value.queryItems?.append(.init(name: "column", value: String(column))) }
      return value.url
    }
    var value = URLComponents()
    value.scheme = editor.rawValue
    value.host = "file"
    value.path = path + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
    return value.url
  }
}

enum InspectorSourceEditor: String, CaseIterable, Identifiable {
  case vscode, cursor, zed, idea, showOnly
  var id: String { rawValue }
  var label: String {
    switch self {
    case .vscode: "VS Code"
    case .cursor: "Cursor"
    case .zed: "Zed"
    case .idea: "JetBrains"
    case .showOnly: InspectorL10n.string("Show location")
    }
  }
}

@MainActor @Observable
final class InspectorSourceActions {
  @ObservationIgnored weak var inspector: InspectorModel?
  private(set) var busy = false
  private(set) var failure: String?
  private(set) var location: String?
  @ObservationIgnored private var revision = 0

  init(inspector: InspectorModel) { self.inspector = inspector }

  static func openLocation(_ location: InspectorSourceLocation, editor: InspectorSourceEditor)
    -> Bool
  {
    guard let url = location.editorURL(editor) else { return false }
    return NSWorkspace.shared.open(url)
  }
  func cancel() {
    revision += 1
    failure = nil
    location = nil
  }

  private struct Hint: Decodable {
    let source: String
    let component: String
    let chain: [String]
    let kind: String
  }

  private func hint(_ inspector: InspectorModel) async throws -> Hint? {
    _ = try await inspector.evaluate(InspectorSourceScript.install)
    guard let raw = try await inspector.evaluate("globalThis.__shaarInspectorSource.resolve()")
    else { return nil }
    let data = try JSONSerialization.data(withJSONObject: raw)
    guard data.count <= 8192, let literal = String(data: data, encoding: .utf8),
      let sanitized = try await inspector.evaluate(
        "globalThis.__shaarInspectorCopy.sanitize(\(literal))")
    else { return nil }
    return try JSONDecoder().decode(
      Hint.self, from: JSONSerialization.data(withJSONObject: sanitized))
  }

  func open() async {
    guard !Task.isCancelled, !busy, let inspector, inspector.aiCopy.canCopy else { return }
    busy = true
    failure = nil
    location = nil
    defer { busy = false }
    let operation = revision
    let generation = inspector.documentGeneration
    do {
      let context = try await inspector.aiCopy.context(captureDetails: false)
      let result = try await hint(inspector)
      guard revision == operation, inspector.documentGeneration == generation,
        inspector.selection?.id == context.id
      else { return }
      let source = result.flatMap { $0.source.isEmpty ? nil : $0.source } ?? context.source
      guard InspectorAIFormatter.available(source) else {
        failure = InspectorL10n.string("Source location is not exposed for this element.")
        return
      }
      location = InspectorL10n.display(InspectorAIFormatter.url(source))
      let editor =
        InspectorSourceEditor(
          rawValue: UserDefaults.standard.string(forKey: "inspectorSourceEditor") ?? "vscode")
        ?? .vscode
      if let local = InspectorSourceLocation.parse(source),
        Self.openLocation(local, editor: editor)
      {
        location = nil
      }
    } catch {
      if operation == revision { failure = Self.failureMessage(for: error) }
    }
  }

  func copyForAgent(to pasteboard: NSPasteboard = .general) async {
    guard !Task.isCancelled, !busy, let inspector, inspector.aiCopy.canCopy else { return }
    busy = true
    failure = nil
    location = nil
    defer { busy = false }
    let operation = revision
    let generation = inspector.documentGeneration
    do {
      var context = try await inspector.aiCopy.context(captureDetails: false)
      let result = try await hint(inspector)
      guard revision == operation, inspector.documentGeneration == generation,
        inspector.selection?.id == context.id
      else { return }
      if let result, !result.source.isEmpty {
        context.source = result.source
        if !result.chain.isEmpty { context.components = result.chain }
      }
      let locator = try await safeLocator(inspector)
      guard revision == operation, inspector.documentGeneration == generation,
        inspector.selection?.id == context.id
      else { return }
      let markdown = InspectorAgentPayload.markdown(context, locator: locator)
      guard !markdown.isEmpty else { return }
      try InspectorAICopyModel.write(markdown, png: nil, to: pasteboard)
      inspector.presentation.copied("agent context")
    } catch {
      if operation == revision { failure = Self.failureMessage(for: error) }
    }
  }

  static func failureMessage(for error: Error) -> String {
    if error is InspectorFailure || error is DeveloperModeFailure {
      return InspectorL10n.display(error.localizedDescription)
    }
    return InspectorL10n.string("Could not get the source details. Try again.")
  }

  private func safeLocator(_ inspector: InspectorModel) async throws -> String {
    guard let candidate = inspector.selection?.playwright, candidate.count <= 16_384 else {
      return ""
    }
    let literal = String(data: try JSONEncoder().encode(["locator": candidate]), encoding: .utf8)!
    let result = try await inspector.evaluate(
      "globalThis.__shaarInspectorCopy.sanitize(\(literal))")
    return (result as? [String: String])?["locator"] ?? ""
  }
}
