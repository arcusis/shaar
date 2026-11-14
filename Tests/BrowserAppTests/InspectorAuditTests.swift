// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@MainActor
private final class PendingInspectorSelectionRuntime: ARCChromiumRuntime {
  private(set) var selectionReply: (@MainActor @Sendable ([String: Any]?, (any Error)?) -> Void)?
  private(set) var followUpCalls = 0
  private let pageView = NSView()

  override func view(
    forPrivateTabID tabID: String, windowID: String, contextID: String
  ) -> NSView? { pageView }

  override func beginInspector(
    forPrivateTabID tabID: String, windowID: String, contextID: String
  ) -> Bool { true }

  override func endInspector(forTabID tabID: String) {}

  override func privateInspectorCall(
    _ method: String, params: [AnyHashable: Any], tabID: String, windowID: String,
    contextID: String,
    completion: @escaping @MainActor @Sendable ([String: Any]?, (any Error)?) -> Void
  ) {
    let expression = params["expression"] as? String ?? ""
    if expression.contains("__shaarInspectorV2?.select(node)") {
      selectionReply = completion
    } else {
      followUpCalls += 1
      completion(["result": ["value": false]], nil)
    }
  }

  func completeSelection() {
    selectionReply?(["result": ["value": true]], nil)
    selectionReply = nil
  }
}

@Suite @MainActor struct InspectorAuditTests {
  @Test func cancelledSelectionDoesNotRefreshInspectorWhenReplyArrives() async throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PendingInspectorSelectionRuntime()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "selection-context", windowID: "selection-window",
      firstTabID: tabID, store: store)
    session.tabChanged(
      tabID, url: "https://example.test", title: "Fixture", loading: false,
      back: false, forward: false)
    let inspector = InspectorModel(target: try #require(session.inspectorTarget), privateSession: session)
    inspector.open()
    defer { inspector.close() }
    let finding = InspectorAuditModel.Finding(
      id: "image-alt:0", ruleID: "image-alt", impact: "serious", title: "Image alt",
      help: "Add alt text.", helpURL: "https://example.test/help", target: "#image",
      summary: "Image is missing alt text")
    let audit = inspector.details.audit
    audit.select(finding)
    for _ in 0..<100 where runtime.selectionReply == nil { await Task.yield() }
    try #require(runtime.selectionReply != nil)

    audit.cancel()
    let callsBeforeReply = runtime.followUpCalls
    runtime.completeSelection()
    for _ in 0..<100 where runtime.followUpCalls == callsBeforeReply { await Task.yield() }
    #expect(runtime.followUpCalls == callsBeforeReply)
  }

  @Test func staleAuditCompletionCannotClearNewerOperation() throws {
    let inspector = makeInspector(tab: .accessibility)
    defer { inspector.close() }
    let audit = inspector.details.audit

    audit.run()
    let staleOperation = try #require(audit.operationID)
    audit.cancel()
    audit.run()
    let currentOperation = try #require(audit.operationID)
    #expect(currentOperation != staleOperation)

    audit.finishOperation(staleOperation)

    #expect(audit.busy)
    #expect(audit.operationID == currentOperation)
    audit.cancel()
  }

  @Test func boundedAuditReportsRejectStaleDocuments() throws {
    let inspector = makeInspector(tab: .accessibility)
    defer { inspector.close() }
    let finding = InspectorAuditModel.Finding(
      id: "button-name:0", ruleID: "button-name", impact: "serious",
      title: "Buttons must have discernible text", help: "Provide an accessible name.",
      helpURL: "https://dequeuniversity.com/rules/axe/4.14/button-name", target: "#save",
      summary: "Fix the following: Element has no accessible name")
    let report = InspectorAuditModel.Report(
      scope: "page", violations: 1, incomplete: 2, findings: [finding], truncated: false)
    try inspector.details.audit.receive(
      report, generation: inspector.documentGeneration, selectionID: nil)
    #expect(inspector.details.audit.report?.findings.first?.target == "#save")
    #expect(report.valid)
    let oversized = InspectorAuditModel.Report(
      scope: "page", violations: 1, incomplete: 0,
      findings: Array(repeating: finding, count: 301), truncated: true)
    #expect(!oversized.valid)

    let oldGeneration = inspector.documentGeneration
    inspector.documentChanged(url: inspector.target.url, committed: true)
    #expect(throws: CancellationError.self) {
      try inspector.details.audit.receive(report, generation: oldGeneration, selectionID: nil)
    }
    #expect(inspector.details.audit.report == nil)
  }

  @Test func auditAndInactiveCSSPanelsRenderOffscreenInBothAppearances() async throws {
    let inspector = makeInspector(tab: .accessibility)
    defer { inspector.close() }
    let finding = InspectorAuditModel.Finding(
      id: "image-alt:0", ruleID: "image-alt", impact: "critical",
      title: "Images must have alternate text",
      help: "Add an alt attribute.",
      helpURL: "https://dequeuniversity.com/rules/axe/4.14/image-alt",
      target: "#missing-alt", summary: "Fix the following: Element has no alt attribute")
    try inspector.details.audit.receive(
      .init(scope: "page", violations: 1, incomplete: 1, findings: [finding], truncated: false),
      generation: inspector.documentGeneration, selectionID: nil)
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    try inspector.details.receive(
      .accessibility(.init(aria: [], tabOrder: 2, tabLimit: false, warnings: [])), selectionID: 8,
      generation: inspector.documentGeneration)
    let directory = URL(filePath: "build/Verification/InspectorAudit")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let image = try await InspectorPanelTests.render(
        InspectorPanel(model: inspector), scheme: scheme)
      try image.write(to: directory.appending(path: "a11y-\(suffix(scheme)).png"), options: .atomic)
    }

    inspector.tab = .styles
    try inspector.styles.receive(
      rules: [
        .init(
          id: 0, selector: ".save", source: "/fixture.css:1",
          declarations: [
            .init(name: "justify-content", value: "center"),
            .init(name: "z-index", value: "2"),
          ])
      ],
      computed: [.init(name: "display", value: "block"), .init(name: "position", value: "static")],
      inactiveHints: [
        "justify-content": "Requires a flex or grid container.",
        "z-index": "Does not apply to static elements outside flex or grid layouts.",
      ], selectionID: 8, generation: inspector.documentGeneration)
    for scheme in [ColorScheme.light, .dark] {
      let image = try await InspectorPanelTests.render(
        InspectorPanel(model: inspector), scheme: scheme)
      try image.write(to: directory.appending(path: "css-\(suffix(scheme)).png"), options: .atomic)
    }
  }

  @Test func packagedAuditBundleLoadsAndAMissingAppBundleDoesNotTrap() throws {
    let present = try fixtureApp(includeAudit: true)
    defer { try? FileManager.default.removeItem(at: present.deletingLastPathComponent()) }
    let presentHost = try #require(Bundle(url: present))
    var usedFallback = false
    let runner = try InspectorAuditModel.resourceText(
      "runner", extension: "js", host: presentHost,
      fallback: {
        usedFallback = true
        return .main
      })
    #expect(runner == "packaged runner")
    #expect(!usedFallback)

    let missing = try fixtureApp(includeAudit: false)
    defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }
    let missingHost = try #require(Bundle(url: missing))
    let error = #expect(throws: InspectorFailure.self) {
      try InspectorAuditModel.resourceText(
        "runner", extension: "js", host: missingHost,
        fallback: {
          usedFallback = true
          return .main
        })
    }
    #expect(
      error?.errorDescription
        == InspectorDetailsL10n.string("The accessibility audit is unavailable."))
    #expect(!usedFallback)
  }

  @Test func pinnedAxeRunnerHasNoPersistentPageScriptNode() throws {
    let runnerURL = try #require(
      try? InspectorAuditModel.resourceText("runner", extension: "js"))
    let runner = runnerURL
    let context = try #require(JSContext())
    let parse = try #require(
      context.evaluateScript("source => { new Function('return '+source); return true; }"))
    #expect(parse.call(withArguments: [runner])?.toBool() == true)
    #expect(context.exception == nil)
  }

  private func makeInspector(tab: InspectorModel.Tab) -> InspectorModel {
    let inspector = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    inspector.open()
    inspector.tab = tab
    return inspector
  }

  private func suffix(_ scheme: ColorScheme) -> String {
    scheme == .dark ? "dark" : "light"
  }

  private func fixtureApp(includeAudit: Bool) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Fixture.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "test.audit", "CFBundlePackageType": "APPL"],
      format: .xml, options: 0)
    try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
    guard includeAudit else { return app }
    let audit = resources.appendingPathComponent(
      "ArcusisBrowser_ArcusisBrowser.bundle/InspectorAudit")
    try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
    try info.write(
      to: resources.appendingPathComponent("ArcusisBrowser_ArcusisBrowser.bundle/Info.plist"))
    try Data("packaged runner".utf8).write(to: audit.appendingPathComponent("runner.js"))
    return app
  }
}
