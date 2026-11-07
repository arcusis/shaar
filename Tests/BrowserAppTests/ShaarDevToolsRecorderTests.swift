// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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
}

@MainActor private final class RecorderScriptLog {
  var expressions: [String] = []
  var next: Any?
}
