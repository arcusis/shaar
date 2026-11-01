// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorPageToolsTests {
  @Test func pageSnapshotsRetainUnknownsAndRejectStaleDocuments() throws {
    let (inspector, _, tools) = makeModels()
    defer {
      tools.stop()
      inspector.close()
    }
    try tools.receive(snapshot(), generation: inspector.documentGeneration)
    #expect(tools.startedAt != nil)
    #expect(tools.console.count == 1 && tools.console[0].message == "fixture error")
    #expect(tools.requests.count == 1)
    #expect(tools.requests[0].method == "UNKNOWN")
    #expect(tools.requests[0].bytes == nil)
    let generation = inspector.documentGeneration
    inspector.documentChanged(url: inspector.target.url, committed: true)
    #expect(throws: CancellationError.self) {
      try tools.receive(snapshot(), generation: generation)
    }
    tools.documentChanged()
    #expect(tools.console.isEmpty && tools.requests.isEmpty && tools.startedAt == nil)
    tools.stop()
    #expect(throws: CancellationError.self) {
      try tools.receive(snapshot(), generation: inspector.documentGeneration)
    }
  }

  @Test func technologiesAndStorageValidateBoundedUntrustedData() throws {
    let (inspector, _, tools) = makeModels()
    defer {
      tools.stop()
      inspector.close()
    }
    let signal = ["name": "React", "version": "18.3.1", "source": "Runtime version"]
    try tools.receiveTechnologies([signal, signal], generation: inspector.documentGeneration)
    #expect(tools.signals.count == 1)
    #expect(throws: InspectorFailure.self) {
      try tools.receiveTechnologies(
        Array(repeating: signal, count: 21), generation: inspector.documentGeneration)
    }
    try tools.receiveStorage(
      ["items": [["key": "", "preview": "empty-key value", "length": 15]], "truncated": true],
      area: "local", generation: inspector.documentGeneration)
    #expect(tools.storage.first?.key == "" && tools.storageLimited)
    #expect(throws: InspectorFailure.self) {
      try tools.receiveStorage(
        ["items": [["key": "bad", "preview": "", "length": -1]]], area: "local",
        generation: inspector.documentGeneration)
    }
    tools.storageArea = "session"
    #expect(throws: CancellationError.self) {
      try tools.receiveStorage(
        ["items": []], area: "local", generation: inspector.documentGeneration)
    }
  }

  @Test func nativePageTabsRenderLiveDataAndSimulationControlsOffscreen() async throws {
    let (inspector, developer, tools) = makeModels()
    defer {
      tools.stop()
      inspector.close()
    }
    try tools.receive(snapshot(), generation: inspector.documentGeneration)
    try tools.receiveTechnologies(
      [["name": "Vue", "version": "3.5.42", "source": "Component runtime marker"]],
      generation: inspector.documentGeneration)
    developer.performanceSnapshot = PagePerformanceSnapshot(
      page: ["lcp": 2300, "inp": 220, "cls": 0.3, "fps": 60, "requests": 8, "bytes": 10_240],
      engineMetrics: [["name": "JSHeapUsedSize", "value": 2_097_152]])
    try tools.receiveStorage(
      ["items": [["key": "theme", "preview": "dark", "length": 4]]], area: "local",
      generation: inspector.documentGeneration)
    for tool in InspectorPageToolsModel.Tool.allCases {
      tools.tool = tool
      for scheme in [ColorScheme.light, .dark] {
        #expect(
          try await InspectorPanelTests.render(
            InspectorPageToolsView(inspector: inspector, model: tools), scheme: scheme
          ).count > 4_096)
      }
    }
    #expect(InspectorPageToolsView.bytes(2048).contains("2"))
    #expect(await developer.createBugReport() == nil)
    #expect(developer.reportFailure != nil && !developer.creatingBugReport)
  }

  @Test func simulationLifecycleRejectsClosedOrNonWebTargets() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let developer = DeveloperPageModel(target: target, engine: nil)
    #expect(!developer.hasActiveSimulation)
    var simulation = DeveloperSimulation()
    simulation.darkMode = true
    developer.set(simulation)
    #expect(developer.simulation.darkMode)
    await #expect(throws: DeveloperModeFailure.self) {
      _ = try await developer.call("Runtime.evaluate")
    }
    developer.close()
    developer.set(DeveloperSimulation())
    #expect(developer.simulation.darkMode)
    let internalTarget = SiteControlTarget(
      tabID: UUID(), profileID: target.profileID, url: URL(string: "about:blank")!)
    let internalModel = DeveloperPageModel(target: internalTarget, engine: nil)
    internalModel.set(simulation)
    #expect(!internalModel.simulation.isActive)
    internalModel.close()
  }

  @Test func collectorDisposalIsOwnerBoundAndJSONEscaped() throws {
    let context = try #require(JSContext())
    let first = "old-owner"
    let second = "new-owner"
    context.evaluateScript(
      "globalThis.disposed=false;globalThis.__shaarBugReportV1={owner:'new-owner',dispose(){globalThis.disposed=true;}}"
    )
    context.evaluateScript(InspectorDiagnosticsScript.dispose(owner: first))
    #expect(context.evaluateScript("disposed")?.toBool() == false)
    context.evaluateScript(
      InspectorDiagnosticsScript.dispose(owner: "');globalThis.disposed=true;//"))
    #expect(context.evaluateScript("disposed")?.toBool() == false)
    context.evaluateScript(InspectorDiagnosticsScript.dispose(owner: second))
    #expect(context.evaluateScript("disposed")?.toBool() == true)
    #expect(context.exception == nil)
  }

  @Test func shippedDiagnosticScriptsParseAsJavaScript() throws {
    let context = try #require(JSContext())
    for source in [InspectorDiagnosticsScript.install, PagePerformanceScript.install] {
      #expect(
        context.evaluateScript("source => { new Function(source); return true; }")?.call(
          withArguments: [source])?.toBool() == true)
      #expect(context.exception == nil)
    }
  }

  private func makeModels() -> (InspectorModel, DeveloperPageModel, InspectorPageToolsModel) {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    let developer = DeveloperPageModel(target: target, engine: nil)
    let tools = InspectorPageToolsModel(inspector: inspector, developer: developer)
    tools.start()
    return (inspector, developer, tools)
  }

  private func snapshot() -> [String: Any] {
    [
      "startedAt": 1_700_000_000_000.0, "timeOrigin": 1_700_000_000_000.0,
      "console": [["level": "error", "message": "fixture error", "time": 1_700_000_000_002.0]],
      "resources": [
        [
          "url": "https://example.com/app.js", "start": 1.0, "duration": 2.0, "status": 200,
          "initiator": "script",
        ]
      ],
    ]
  }
}
