// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class InspectorAuditModel {
  enum Scope: String, CaseIterable {
    case page
    case selected
  }

  struct Finding: Decodable, Identifiable {
    let id: String
    let ruleID: String
    let impact: String
    let title: String
    let help: String
    let helpURL: String
    let target: String
    let summary: String

    enum CodingKeys: String, CodingKey {
      case id, impact, title, help, target, summary
      case ruleID = "ruleId"
      case helpURL = "helpUrl"
    }

    var valid: Bool {
      !id.isEmpty && id.count <= 256 && ruleID.count <= 128 && impact.count <= 32
        && title.count <= 256 && help.count <= 512 && helpURL.count <= 2048
        && target.count <= 2048 && summary.count <= 2048
    }
  }

  struct Report: Decodable {
    let scope: String
    let violations: Int
    let incomplete: Int
    let findings: [Finding]
    let truncated: Bool

    var valid: Bool {
      ["page", "selected"].contains(scope) && (0...1000).contains(violations)
        && (0...1000).contains(incomplete) && findings.count <= 300
        && findings.allSatisfy(\.valid)
    }
  }

  static let axeVersion = "4.14.0"
  @ObservationIgnored weak var inspector: InspectorModel?
  private(set) var scope = Scope.page
  private(set) var report: Report?
  private(set) var failure: String?
  private(set) var busy = false
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private(set) var operationID: UUID?
  @ObservationIgnored private var selectionTask: Task<Void, Never>?
  @ObservationIgnored private var selectionRequestID = UUID()

  init(inspector: InspectorModel?) { self.inspector = inspector }

  func setScope(_ value: Scope) {
    guard !busy else { return }
    scope = value
    report = nil
    failure = nil
  }

  func run() {
    guard !busy, let inspector, inspector.isOpen else { return }
    guard scope != .selected || inspector.selection?.locked == true else {
      failure = InspectorDetailsL10n.string("Lock an element before auditing this selection.")
      return
    }
    let generation = inspector.documentGeneration
    let selectionID = scope == .selected ? inspector.selection?.id : nil
    let requestedScope = scope
    busy = true
    failure = nil
    let operationID = UUID()
    self.operationID = operationID
    operation = Task { [weak self] in
      await self?.perform(
        requestedScope, generation: generation, selectionID: selectionID,
        operationID: operationID)
    }
  }

  func cancel() {
    operation?.cancel()
    operation = nil
    operationID = nil
    selectionRequestID = UUID()
    selectionTask?.cancel()
    selectionTask = nil
    busy = false
    report = nil
    failure = nil
  }

  func selectionChanged() {
    if report?.scope == Scope.selected.rawValue { report = nil }
  }

  func reset() { cancel() }

  func receive(_ report: Report, generation: Int, selectionID: Int?) throws {
    guard let inspector, inspector.isOpen, inspector.documentGeneration == generation,
      selectionID == nil || inspector.selection?.id == selectionID, report.valid
    else { throw CancellationError() }
    self.report = report
    failure = nil
  }

  func select(_ finding: Finding) {
    guard !finding.target.isEmpty, let inspector, inspector.isOpen else { return }
    let generation = inspector.documentGeneration
    let selector = Self.stringLiteral(finding.target)
    let expression = """
      (()=>{try{const node=document.querySelector(\(selector));return node?globalThis.__shaarInspectorV2?.select(node)===true:false;}catch{return false;}})()
      """
    operation?.cancel()
    selectionTask?.cancel()
    let requestID = UUID()
    selectionRequestID = requestID
    let selectedReport = report?.scope == Scope.selected.rawValue
    selectionTask = Task { [weak self, weak inspector] in
      await self?.selectTarget(
        expression, generation: generation, selectedReport: selectedReport, inspector: inspector,
        requestID: requestID)
    }
  }

  func finishOperation(_ operationID: UUID) {
    guard self.operationID == operationID else { return }
    busy = false
    operation = nil
    self.operationID = nil
  }

  private func perform(
    _ scope: Scope, generation: Int, selectionID: Int?, operationID: UUID
  ) async {
    defer { finishOperation(operationID) }
    guard let inspector else { return }
    do {
      let source = try Self.resourceText("axe.min", extension: "js")
      let runner = try Self.resourceText("runner", extension: "js")
      let result = try await inspector.evaluate(
        Self.expression(source: source, runner: runner, scope: scope))
      guard !Task.isCancelled else { throw CancellationError() }
      let data = try JSONSerialization.data(withJSONObject: result ?? NSNull())
      let next = try JSONDecoder().decode(Report.self, from: data)
      guard next.valid, next.scope == scope.rawValue else {
        throw InspectorFailure(
          InspectorDetailsL10n.string("Audit results exceeded supported limits."))
      }
      try receive(next, generation: generation, selectionID: selectionID)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, inspector.documentGeneration == generation else { return }
      failure = Self.failureMessage(for: error)
    }
  }

  static func failureMessage(for error: Error) -> String {
    if error is InspectorFailure || error is DeveloperModeFailure {
      return InspectorL10n.display(error.localizedDescription)
    }
    return InspectorL10n.string("Could not complete the page audit. Try again.")
  }

  private func selectTarget(
    _ expression: String, generation: Int, selectedReport: Bool, inspector: InspectorModel?,
    requestID: UUID
  ) async {
    defer {
      if selectionRequestID == requestID { selectionTask = nil }
    }
    guard let inspector else { return }
    do {
      let selected = try await inspector.evaluate(expression) as? Bool ?? false
      guard !Task.isCancelled, selectionRequestID == requestID, selected, inspector.isOpen,
        inspector.documentGeneration == generation
      else { return }
      if selectedReport { report = nil }
      failure = nil
      await inspector.refresh()
    } catch { return }
  }

  static func resourceText(
    _ name: String,
    extension fileExtension: String,
    host: Bundle = .main,
    fallback: (() -> Bundle)? = nil
  ) throws -> String {
    let bundle = PackagedResourceBundle.resolve(
      named: "ArcusisBrowser_ArcusisBrowser", in: host, fallback: fallback ?? { .module })
    guard
      let bundle,
      let url = bundle.url(
        forResource: name, withExtension: fileExtension, subdirectory: "InspectorAudit"),
      let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty
    else {
      throw InspectorFailure(
        InspectorDetailsL10n.string("The accessibility audit is unavailable."))
    }
    return value
  }

  private static func expression(source: String, runner: String, scope: Scope) -> String {
    "\(runner)(\(stringLiteral(source)), \(stringLiteral(scope.rawValue)))"
  }

  private static func stringLiteral(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
  }
}
