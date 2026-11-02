// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class InspectorAICopyModel {
  typealias Formatter = InspectorAIFormatter
  @ObservationIgnored weak var inspector: InspectorModel?
  @ObservationIgnored var screenshotCache = InspectorScreenshotCache()
  enum CopyKind { case element, withNotes, image }
  var detailed = false
  var intent = Formatter.Intent.change
  var feedback = ""
  private(set) var notes: [Formatter.Note] = []
  private(set) var clearedNotes: [Formatter.Note] = []
  private(set) var busy = false
  private(set) var failure: String?
  private(set) var status: String?
  @ObservationIgnored private var revision = 0
  var canCopy: Bool {
    inspector?.isOpen == true && inspector?.selection?.locked == true && inspector?.mode == .locked
      && !Formatter.formTags.contains(inspector?.selection?.tag ?? "") && !busy
  }

  init(inspector: InspectorModel) { self.inspector = inspector }
  func cancel() {
    revision += 1
    status = nil
    failure = nil
  }

  func context(captureDetails: Bool? = nil) async throws -> Formatter.Context {
    let includeDetails = captureDetails ?? detailed
    guard let inspector, inspector.isOpen, let selection = inspector.selection, selection.locked
    else {
      throw InspectorFailure("Lock an element first.")
    }
    let generation = inspector.documentGeneration
    _ = try await inspector.evaluate(InspectorAICopyScript.install)
    guard
      let raw = try await inspector.evaluate(
        "globalThis.__shaarInspectorCopy.context(\(selection.id))")
    else {
      throw InspectorFailure("Element context is unavailable.")
    }
    let data = try JSONSerialization.data(withJSONObject: raw)
    guard data.count < 524_288 else {
      throw InspectorFailure("Element context exceeds the copy limit.")
    }
    var context = try JSONDecoder().decode(Formatter.Context.self, from: data)
    guard context.valid else { throw InspectorFailure("Choose an element outside form controls.") }
    if inspector.details.selectedID == selection.id {
      context.source = inspector.details.component?.source ?? context.source
      if let tree = inspector.details.tree, let selected = tree.selected {
        var chain: [String] = []
        var current: Int? = selected
        while let id = current, chain.count < 32,
          let node = tree.nodes.first(where: { $0.id == id })
        {
          chain.insert(node.name, at: 0)
          current = node.parent
        }
        if !chain.isEmpty { context.components = chain }
      }
    }
    context.details.technologies = ["React", "Vue", "Svelte"].filter { framework in
      context.components.contains { $0.hasPrefix(framework + ": ") }
    }
    if includeDetails {
      await inspector.styles.refresh(force: true)
      guard inspector.styles.selectedID == selection.id, inspector.styles.failure == nil else {
        throw InspectorFailure(inspector.styles.failure ?? "Computed styles are unavailable.")
      }
      context.details.computed = inspector.styles.computed.map {
        .init(name: $0.name, value: $0.value)
      }
      context.details.rules = inspector.styles.rules.map { rule in
        .init(
          selector: rule.selector, source: rule.source,
          declarations: rule.declarations.map { .init(name: $0.name, value: $0.value) })
      }
      if let tools = inspector.pageTools {
        context.details.consoleErrors = tools.console.filter {
          ["error", "unhandledrejection"].contains($0.level)
        }.suffix(30).map(\.message)
        context.details.networkErrors = tools.requests.filter {
          $0.status >= 400
        }.suffix(30).map { "\($0.method) \($0.url) — status \($0.status)" }
        context.details.technologies = tools.signals.map {
          $0.name + ($0.version.map { " " + $0 } ?? "")
        }
      } else {
        context.details.consoleErrors = ["Unavailable: Page diagnostics have not been enabled."]
        context.details.networkErrors = ["Unavailable: Page diagnostics have not been enabled."]
      }
    }
    // Enrichments use existing Inspector data, then pass through the page's current form-value scrubber.
    let full = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Envelope(context: context, details: context.details)))
    let literal = String(data: try JSONSerialization.data(withJSONObject: full), encoding: .utf8)!
    guard literal.utf8.count <= 2_097_152,
      let safe = try await inspector.evaluate(
        "globalThis.__shaarInspectorCopy.sanitize(\(literal))")
    else { throw InspectorFailure("Detailed context exceeds the copy limit.") }
    let envelope = try JSONDecoder().decode(
      Envelope.self, from: JSONSerialization.data(withJSONObject: safe))
    context = envelope.context
    context.details = envelope.details
    guard inspector.isOpen, inspector.documentGeneration == generation,
      inspector.selection?.id == selection.id, context.valid
    else { throw CancellationError() }
    return context
  }
  private struct Envelope: Codable {
    let context: Formatter.Context
    let details: Formatter.Details
  }

  func copyElement(to pasteboard: NSPasteboard = .general) async {
    await copy(.element, to: pasteboard)
  }

  func copy(_ kind: CopyKind, to pasteboard: NSPasteboard = .general) async {
    guard !busy else { return }
    busy = true
    failure = nil
    status = nil
    defer { busy = false }
    let operation = revision
    let includeDetails = detailed
    do {
      let context = try await context(captureDetails: kind == .image ? false : includeDetails)
      guard let inspector else { throw CancellationError() }
      let generation = inspector.documentGeneration
      guard
        let token = try await inspector.evaluate(
          "globalThis.__shaarInspectorCopy.begin(\(context.id))") as? String
      else {
        throw InspectorFailure("The private element capture could not start.")
      }
      let tokenJSON = String(data: try JSONEncoder().encode(token), encoding: .utf8)!
      let png: Data
      do { png = try await inspector.styles.screenshot() } catch {
        _ = try? await inspector.evaluate(
          "globalThis.__shaarInspectorCopy?.end(\(tokenJSON)); true")
        throw error
      }
      guard
        try await inspector.evaluate("globalThis.__shaarInspectorCopy?.end(\(tokenJSON))") as? Bool
          == true
      else {
        throw InspectorFailure("The page changed during the private capture. Try again.")
      }
      guard operation == revision, inspector.isOpen, inspector.documentGeneration == generation,
        inspector.selection?.id == context.id
      else { throw CancellationError() }
      let file = try screenshotCache.save(png, tag: context.tag)
      var markdown = Formatter.element(context, detailed: includeDetails, screenshotPath: file.path)
      if kind == .withNotes, !notes.isEmpty {
        markdown += "\n" + Formatter.notes(notes, detailed: includeDetails)
      }
      try Self.write(kind == .image ? nil : markdown, png: png, to: pasteboard)
      status = kind == .image ? "Copied image to clipboard" : "Copied element to clipboard"
      inspector.presentation.copied(kind == .image ? "image" : "element")
    } catch { if operation == revision { failure = error.localizedDescription } }
  }

  func addNote() async {
    guard !busy, notes.count < 50, !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    busy = true
    failure = nil
    status = nil
    defer { busy = false }
    let operation = revision
    let comment = feedback
    let selectedIntent = intent
    do {
      let value = try await context(captureDetails: true)
      guard operation == revision else { throw CancellationError() }
      append(context: value, feedback: comment, intent: selectedIntent)
      if feedback == comment { feedback = "" }
      status = "Note added"
    } catch { if operation == revision { failure = error.localizedDescription } }
  }

  func append(context: Formatter.Context, feedback: String, intent: Formatter.Intent) {
    guard context.valid, notes.count < 50,
      !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    notes.append(
      .init(
        id: UUID(), context: context, intent: intent,
        feedback: Formatter.text(feedback, limit: 2000)))
  }

  func delete(_ id: UUID) { notes.removeAll { $0.id == id } }
  func clear() {
    guard !notes.isEmpty else { return }
    clearedNotes = notes
    notes = []
    status = "Notes cleared"
  }
  func undoClear() {
    let existing = Set(notes.map(\.id))
    let candidates = clearedNotes.filter { !existing.contains($0.id) }
    let restored = Array(candidates.prefix(max(0, 50 - notes.count)))
    notes = restored + notes
    clearedNotes = Array(candidates.dropFirst(restored.count))
    status =
      clearedNotes.isEmpty
      ? "Notes restored" : "Delete a note to restore the remaining cleared notes."
  }

  func copyNotes(to pasteboard: NSPasteboard = .general) {
    guard !notes.isEmpty, !busy else { return }
    do {
      try Self.write(Formatter.notes(notes, detailed: detailed), png: nil, to: pasteboard)
      clear()
      status = "Copied notes to clipboard"
      inspector?.presentation.copied("notes")
    } catch { failure = error.localizedDescription }
  }
  static func write(_ markdown: String?, png: Data?, to pasteboard: NSPasteboard) throws {
    let text = NSPasteboardItem()
    if let markdown {
      text.setString(markdown, forType: .string)
      text.setString(markdown, forType: .init("net.daringfireball.markdown"))
    }
    if let png {
      guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), NSBitmapImageRep(data: png) != nil
      else {
        throw InspectorFailure("The element image is invalid.")
      }
      text.setData(png, forType: .png)
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([text]) else {
      throw InspectorFailure("The clipboard could not be written.")
    }
  }
}
