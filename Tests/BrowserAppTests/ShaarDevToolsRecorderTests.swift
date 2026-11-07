// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@MainActor @Suite struct ShaarDevToolsRecorderTests {
  @Test func recordsAClickAndAnInputInOrder() {
    let model = ShaarDevToolsRecorderModel()
    model.apply(Self.clickAndInput + [["kind": "hover", "selector": "#x", "value": ""]])
    #expect(model.steps.map(\.kind) == [.click, .change])
    #expect(model.steps.map(\.selector) == ["#save", "input[name=email]"])
    #expect(model.steps[1].value == "ada@example.com")
  }

  @Test func deletingAStepLeavesTheRest() {
    let model = ShaarDevToolsRecorderModel()
    model.apply(Self.clickAndInput)
    model.deleteStep(model.steps[0].id)
    #expect(model.steps.map(\.kind) == [.change])
    #expect(model.steps.map(\.selector) == ["input[name=email]"])
  }

  @Test func replayScriptClicksAndFillsTheRemainingSteps() {
    let model = ShaarDevToolsRecorderModel()
    model.apply(Self.clickAndInput + [Self.navigation])
    model.deleteStep(model.steps[2].id)
    let script = ShaarDevToolsRecorder.replaySource(model.steps)
    #expect(script.contains("#save"))
    #expect(script.contains(".click()"))
    #expect(script.contains("ada@example.com"))
    #expect(script.contains("input[name=email]"))
    #expect(!script.contains("https://example.com/next"))
    let quoted = ShaarDevToolsRecorderModel()
    quoted.apply([["kind": "change", "selector": "#q", "value": "a\"b"]])
    #expect(ShaarDevToolsRecorder.replaySource(quoted.steps).contains(#"a\"b"#))
  }

  @Test func changingTabsClearsTheRecording() {
    let model = ShaarDevToolsRecorderModel()
    model.apply(Self.clickAndInput)
    model.retarget(tabChanged: false, committed: true)
    #expect(model.steps.count == 2)
    model.retarget(tabChanged: true, committed: true)
    #expect(model.steps.isEmpty)
    #expect(model.recording == false)
  }

  @Test func exportWritesFlowJSONApartFromRepro() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "shaar-flow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ShaarDevToolsRecorderModel()
    model.apply(Self.clickAndInput)
    let url = try model.exportFile(in: directory)
    #expect(url.lastPathComponent.hasPrefix("shaar-flow-"))
    #expect(url.pathExtension == "json")
    #expect(!url.lastPathComponent.contains("repro"))
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["kind"] as? String == "shaar-flow")
    let steps = try #require(object["steps"] as? [[String: Any]])
    #expect(steps.count == 2)
    #expect(steps[0]["kind"] as? String == "click")
    #expect(steps[1]["value"] as? String == "ada@example.com")
  }

  @Test func startInstallsTheListenerAndPullsSteps() async {
    let log = RecorderScriptLog()
    log.next = Self.clickAndInput
    let model = ShaarDevToolsRecorderModel()
    model.evaluate = { expression in
      log.expressions.append(expression)
      return log.next
    }
    await model.start()
    #expect(model.recording)
    #expect(log.expressions.first == ShaarDevToolsRecorder.installSource)
    #expect(log.expressions.contains(ShaarDevToolsRecorder.drainSource))
    #expect(model.steps.map(\.kind) == [.click, .change])
    log.next = []
    await model.stop()
    #expect(model.recording == false)
    #expect(log.expressions.contains(ShaarDevToolsRecorder.uninstallSource))
  }

  @Test func recordingWithoutAPageStaysIdle() async {
    let model = ShaarDevToolsRecorderModel()
    await model.start()
    #expect(model.recording == false)
    #expect(model.notice == .needsPage)
    await model.replay()
    #expect(model.notice == .needsPage)
  }

  private static let clickAndInput: [[String: Any]] = [
    ["kind": "click", "selector": "#save", "value": ""],
    ["kind": "change", "selector": "input[name=email]", "value": "ada@example.com"],
  ]

  private static let navigation: [String: Any] = [
    "kind": "navigation", "selector": "", "value": "https://example.com/next",
  ]

  @Test func recorderPanelRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    let idle = ShaarDevToolsRecorderModel()
    let empty = try renderRecorder(idle, width: 640, height: 420)

    let needsPage = ShaarDevToolsRecorderModel()
    await needsPage.start()
    #expect(needsPage.notice == .needsPage)
    let page = try renderRecorder(needsPage, width: 640, height: 420)

    let folder = ShaarDevToolsRecorderModel()
    folder.noteMissingFolder()
    #expect(folder.notice == .needsFolder)
    let folderImage = try renderRecorder(folder, width: 640, height: 420)

    let saved = ShaarDevToolsRecorderModel()
    saved.noteSaved()
    #expect(saved.notice == .saved)
    let savedImage = try renderRecorder(saved, width: 640, height: 420)

    let rejected = ShaarDevToolsRecorderModel()
    rejected.evaluate = { _ in throw ShaarRecorderFailure("Recorder was rejected.") }
    await rejected.start()
    #expect(rejected.notice == .failed("Recorder was rejected."))
    let failed = try renderRecorder(rejected, width: 640, height: 420)

    let recordingModel = ShaarDevToolsRecorderModel()
    recordingModel.evaluate = { _ in [] }
    await recordingModel.start()
    #expect(recordingModel.recording)
    let recording = try renderRecorder(recordingModel, width: 640, height: 420)
    await recordingModel.stop()
    #expect(recordingModel.recording == false)

    let populated = ShaarDevToolsRecorderModel()
    populated.apply(Self.clickAndInput + [Self.navigation])
    #expect(populated.steps.map(\.kind) == [.click, .change, .navigation])
    let rows = try renderRecorder(populated, width: 640, height: 520)

    let defaults = UserDefaults(suiteName: "ShaarRecorder.render.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .recorder
    let shellEmpty = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    shell.recorder.apply(Self.clickAndInput + [Self.navigation])
    let shellRows = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!empty.isEmpty)
    #expect(!page.isEmpty)
    #expect(!folderImage.isEmpty)
    #expect(!savedImage.isEmpty)
    #expect(!failed.isEmpty)
    #expect(!recording.isEmpty)
    #expect(!rows.isEmpty)
    #expect(!shellEmpty.isEmpty)
    #expect(!shellRows.isEmpty)
    shell.close()
  }
}

@MainActor private func renderRecorder(
  _ model: ShaarDevToolsRecorderModel, width: CGFloat, height: CGFloat
) throws -> Data {
  try VisualCapture.pngOffscreen(
    ShaarDevToolsRecorderPanel(model: model), size: NSSize(width: width, height: height))
}

@MainActor private final class RecorderScriptLog {
  var expressions: [String] = []
  var next: Any?
}
