// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@MainActor final class ShaarEventListenerFixture: ShaarEventListenersTransport {
  var commands: [String] = []
  var rows: [ShaarEventListener]

  init() {
    rows = [
      ShaarEventListenerFixture.click,
      ShaarEventListenerFixture.keydown,
    ]
  }

  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    commands.append("listeners \(nodeID) \(ancestors.map(String.init).joined(separator: ","))")
    return rows.filter { $0.nodeID == nodeID || ancestors.contains($0.nodeID) }
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {
    commands.append("remove \(listener.id)")
    rows.removeAll { $0.id == listener.id }
  }

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {
    commands.append("passive \(listener.id) \(passive)")
    update(listener.id) { $0.passive = passive }
  }

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
    commands.append("once \(listener.id) \(once)")
    update(listener.id) { $0.once = once }
  }

  private func update(_ id: String, _ change: (inout ShaarEventListener) -> Void) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    change(&rows[index])
  }

  static let click = ShaarEventListener(
    id: "8|click|0", type: "click", nodeID: 8, onAncestor: false, capture: false,
    passive: false, once: false, source: "app.js:42:3", handlerObjectID: "handler-click")

  static let keydown = ShaarEventListener(
    id: "3|keydown|0", type: "keydown", nodeID: 3, onAncestor: true, capture: true,
    passive: true, once: false, source: "app.js:18:1", handlerObjectID: "handler-keydown")
}

@Suite @MainActor struct ShaarEventListenersTests {
  @Test func fixtureListsClickAndAncestorKeydownThenHidesAncestors() async throws {
    let fixture = ShaarEventListenerFixture()
    let dom = DOMFixtureTransport()
    let tree = ShaarDOMTreeModel(target: listenerTarget(), transport: dom)
    tree.open()
    for _ in 0..<20 where tree.rootID == nil { await Task.yield() }
    tree.select(8)
    let ancestors = ShaarEventListenerAncestors.chain(from: 8, nodes: tree.nodes)
    #expect(ancestors.contains(3))
    let model = ShaarEventListenersModel(target: listenerTarget(), transport: fixture)
    await model.load(nodeID: 8, ancestors: ancestors)
    #expect(model.visibleGroups.map(\.type) == ["click", "keydown"])
    let click = try #require(model.visibleGroups.first { $0.type == "click" }?.rows.first)
    #expect(click.onAncestor == false)
    #expect(click.capture == false)
    #expect(click.source == "app.js:42:3")
    let keydown = try #require(model.visibleGroups.first { $0.type == "keydown" }?.rows.first)
    #expect(keydown.onAncestor == true)
    #expect(keydown.capture == true)
    #expect(keydown.passive == true)
    #expect(keydown.source == "app.js:18:1")
    model.includeAncestors = false
    #expect(model.visibleGroups.map(\.type) == ["click"])
    tree.close()
  }

  @Test func removeAndFlagTogglesUpdateTheFixture() async throws {
    let fixture = ShaarEventListenerFixture()
    let model = ShaarEventListenersModel(target: listenerTarget(), transport: fixture)
    await model.load(nodeID: 8, ancestors: [7, 4, 3, 2, 1])
    await model.togglePassive("8|click|0")
    await model.toggleOnce("8|click|0")
    let click = try #require(model.listeners.first { $0.id == "8|click|0" })
    #expect(click.passive == true)
    #expect(click.once == true)
    #expect(fixture.commands.contains("passive 8|click|0 true"))
    #expect(fixture.commands.contains("once 8|click|0 true"))
    await model.remove("3|keydown|0")
    #expect(model.listeners.contains { $0.id == "3|keydown|0" } == false)
    #expect(model.visibleGroups.map(\.type) == ["click"])
    await model.refresh()
    #expect(fixture.commands.last == "listeners 8 7,4,3,2,1")
    #expect(model.listeners.contains { $0.id == "3|keydown|0" } == false)
    let refreshed = try #require(model.listeners.first { $0.id == "8|click|0" })
    #expect(refreshed.passive == true)
    #expect(refreshed.once == true)
  }

  @Test func pendingTransportStaysEmptyAndEditsNeedEngineSupport() async {
    let model = ShaarEventListenersModel(
      target: listenerTarget(), transport: ShaarEventListenersPendingTransport())
    await model.load(nodeID: 8, ancestors: [3])
    #expect(model.listeners.isEmpty)
    #expect(model.failure == nil)
    #expect(model.visibleGroups.isEmpty)
    let error = await #expect(throws: ShaarEventListenersUnavailable.self) {
      try await ShaarEventListenersPendingTransport().remove(
        ShaarEventListenerFixture.click, target: listenerTarget())
    }
    #expect(error?.errorDescription == "Event listeners need engine support")
  }

  @Test func decoderReadsSourceFlagsAndBridgeNumbers() {
    let payload: [String: Any] = [
      "listeners": [
        [
          "type": "click",
          "useCapture": false,
          "passive": true,
          "once": false,
          "scriptId": "7",
          "lineNumber": 41,
          "columnNumber": 2,
          "handler": ["objectId": "handler-1"],
          "url": "https://example.test/assets/app.js",
        ],
        [
          "type": "keydown",
          "useCapture": NSNumber(value: true),
          "passive": NSNumber(value: false),
          "once": NSNumber(value: true),
          "scriptId": NSNumber(value: 7),
          "lineNumber": NSNumber(value: 17),
          "columnNumber": NSNumber(value: 0),
        ],
      ]
    ]
    let rows = ShaarEventListenerDecoding.listeners(
      from: payload, nodeID: 8, onAncestor: false, nodeObjectID: "node-1")
    #expect(rows.count == 2)
    #expect(rows[0].source == "app.js:42:3")
    #expect(rows[0].passive == true)
    #expect(rows[0].handlerObjectID == "handler-1")
    #expect(rows[0].nodeObjectID == "node-1")
    #expect(rows[1].source == "script 7:18:1")
    #expect(rows[1].capture == true)
    #expect(rows[1].once == true)
    let dropped = ShaarEventListenerDecoding.listeners(
      from: ["listeners": [["type": "click"]]], nodeID: 8, onAncestor: false, nodeObjectID: nil)
    #expect(dropped.isEmpty)
  }

  @Test func requestsKeepListenerEditsInsideTheAllowlist() {
    let listed = ShaarEventListenerRequest.listeners(objectID: "node-1")
    #expect(listed.0 == "DOMDebugger.getEventListeners")
    #expect(listed.1["objectId"] as? String == "node-1")
    #expect(listed.1["depth"] as? Int == 1)
    #expect(listed.1["pierce"] as? Bool == false)
    let remove = ShaarEventListenerRequest.remove(
      ShaarEventListenerFixture.click, nodeObjectID: "node-8")
    let arguments = remove?.1["arguments"] as? [[String: Any]]
    #expect(remove?.0 == "Runtime.callFunctionOn")
    #expect(arguments?.count == 3)
    #expect(arguments?[0]["value"] as? String == "click")
    #expect(arguments?[1]["objectId"] as? String == "handler-click")
    #expect(arguments?[2]["value"] as? Bool == false)
    let passive = ShaarEventListenerRequest.setPassive(
      ShaarEventListenerFixture.click, nodeObjectID: "node-8", passive: true)
    #expect((passive?.1["arguments"] as? [[String: Any]])?.count == 4)
    let once = ShaarEventListenerRequest.setOnce(
      ShaarEventListenerFixture.keydown, nodeObjectID: "node-3", once: true)
    let onceArguments = once?.1["arguments"] as? [[String: Any]]
    #expect(onceArguments?.count == 5)
    #expect(onceArguments?[3]["value"] as? Bool == true)
    #expect(onceArguments?[4]["value"] as? Bool == true)
    var missingHandler = ShaarEventListenerFixture.click
    missingHandler.handlerObjectID = nil
    #expect(ShaarEventListenerRequest.remove(missingHandler, nodeObjectID: "node-8") == nil)
    let longType = ShaarEventListener(
      id: "8|long|0", type: String(repeating: "a", count: 257), nodeID: 8, onAncestor: false,
      capture: false, passive: false, once: false, source: nil, handlerObjectID: "handler")
    #expect(ShaarEventListenerRequest.remove(longType, nodeObjectID: "node-8") == nil)
  }

  @Test func liveTransportResolvesTheNodeAgainBeforeAnEdit() async throws {
    let calls = ListenerCallLog()
    let transport = ShaarEventListenersLiveTransport { method, params, _ in
      calls.entries.append((method, params))
      if method == "DOM.resolveNode" {
        calls.resolves += 1
        return ["object": ["objectId": "node-\(calls.resolves)"]]
      }
      if method == "DOMDebugger.getEventListeners" {
        return [
          "listeners": [
            [
              "type": "click", "useCapture": false, "passive": false, "once": false,
              "scriptId": "7", "lineNumber": 41, "columnNumber": 2,
              "handler": ["objectId": "handler-1"],
            ]
          ]
        ]
      }
      return [:]
    }
    let found = try await transport.listeners(
      nodeID: 8, ancestors: [], target: listenerTarget())
    let click = try #require(found.first)
    #expect(click.source == "script 7:42:3")
    #expect(click.nodeObjectID == nil)
    #expect(click.handlerObjectID == "handler-1")
    try await transport.remove(click, target: listenerTarget())
    let edit = try #require(calls.entries.first { $0.0 == "Runtime.callFunctionOn" })
    #expect(edit.1["objectId"] as? String == "node-2")
    #expect((edit.1["arguments"] as? [[String: Any]])?.count == 3)
    for _ in 0..<30 where calls.entries.filter({ $0.0 == "Runtime.releaseObject" }).count < 2 {
      await Task.yield()
    }
    let released = calls.entries.filter { $0.0 == "Runtime.releaseObject" }.compactMap {
      $0.1["objectId"] as? String
    }
    #expect(released.contains("node-1"))
    #expect(released.contains("handler-1"))
  }

  @Test func liveTransportRebindsAMissingNodeAndReadsItsListeners() async throws {
    let calls = ListenerCallLog()
    let transport = ShaarEventListenersLiveTransport { method, params, _ in
      calls.entries.append((method, params))
      if method == "DOM.resolveNode" {
        let id = params["nodeId"] as? Int
        if id == 8 || id == 3 {
          throw NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No node with given id found"])
        }
        return ["object": ["objectId": "node-\(id ?? 0)"]]
      }
      if method == "DOMDebugger.getEventListeners" {
        return [
          "listeners": [
            ["type": "qa-ping", "useCapture": false, "passive": false, "once": false]
          ]
        ]
      }
      return [:]
    }
    transport.rebind = { ids, _ in
      calls.rebound = ids
      return Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 + 10) })
    }
    let found = try await transport.listeners(
      nodeID: 8, ancestors: [3], target: listenerTarget())
    #expect(found.contains { $0.type == "qa-ping" && $0.onAncestor == false })
    #expect(calls.rebound == [8, 3])
    #expect(calls.entries.contains { $0.0 == "DOM.resolveNode" && ($0.1["nodeId"] as? Int) == 18 })
  }

  @Test func liveTransportLeavesOtherResolveErrorsAlone() async {
    let calls = ListenerCallLog()
    let transport = ShaarEventListenersLiveTransport { method, params, _ in
      calls.entries.append((method, params))
      throw NSError(
        domain: "test", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "DevTools protocol request timed out"])
    }
    transport.rebind = { ids, _ in
      calls.rebound = ids
      return [:]
    }
    do {
      _ = try await transport.listeners(nodeID: 8, ancestors: [], target: listenerTarget())
      Issue.record("A timeout should stay a timeout")
    } catch {
      #expect(error.localizedDescription.contains("timed out"))
    }
    #expect(calls.rebound.isEmpty)
  }

  @Test func liveTransportEditsAncestorFlagsAndRejectsAMissingNode() async throws {
    let calls = ListenerCallLog()
    let transport = ShaarEventListenersLiveTransport { method, params, _ in
      calls.entries.append((method, params))
      if method == "DOM.resolveNode" {
        if params["nodeId"] as? Int == 99 { return ["object": ["objectId": ""]] }
        calls.resolves += 1
        return ["object": ["objectId": "node-\(calls.resolves)"]]
      }
      if method == "DOMDebugger.getEventListeners" {
        return [
          "listeners": [
            [
              "type": "submit", "useCapture": false, "passive": false, "once": true,
              "handler": ["objectId": "handler-submit"],
            ]
          ]
        ]
      }
      return [:]
    }
    let target = listenerTarget()
    let found = try await transport.listeners(nodeID: 8, ancestors: [3], target: target)
    #expect(found.count == 2)
    #expect(found[0].onAncestor == false)
    #expect(found[0].once == true)
    #expect(found[0].source == nil)
    #expect(found[1].onAncestor == true)
    let submit = try #require(found.first)
    try await transport.setPassive(submit, passive: true, target: target)
    try await transport.setOnce(submit, once: false, target: target)
    let edits = calls.entries.filter { $0.0 == "Runtime.callFunctionOn" }
    #expect(edits.count == 2)
    await #expect(throws: ShaarEventListenersUnavailable.self) {
      try await transport.listeners(nodeID: 99, ancestors: [], target: target)
    }
    var missingHandler = submit
    missingHandler.handlerObjectID = nil
    await #expect(throws: ShaarEventListenersUnavailable.self) {
      try await transport.remove(missingHandler, target: target)
    }
  }

  @Test func paneRendersOffscreenEmptyAndPopulated() async throws {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let emptyModel = ShaarEventListenersModel(
      target: listenerTarget(), transport: ShaarEventListenersPendingTransport())
    let empty = try VisualCapture.pngOffscreen(
      ShaarEventListenersPane(model: emptyModel), size: NSSize(width: 520, height: 360))
    let populatedModel = ShaarEventListenersModel(
      target: listenerTarget(), transport: ShaarEventListenerFixture())
    await populatedModel.load(nodeID: 8, ancestors: [3])
    let populated = try VisualCapture.pngOffscreen(
      ShaarEventListenersPane(model: populatedModel), size: NSSize(width: 520, height: 360))
    #expect(!empty.isEmpty)
    #expect(!populated.isEmpty)
    #expect(empty != populated)
    #expect(NSApp.keyWindow === previous)
  }

  @Test func paneRendersLoadingEmptyFailureAndAOnceRow() async throws {
    _ = NSApplication.shared
    let hold = ListenerHoldTransport()
    let loadingModel = ShaarEventListenersModel(target: listenerTarget(), transport: hold)
    let loadingTask = Task { await loadingModel.load(nodeID: 8, ancestors: []) }
    for _ in 0..<100 where !hold.suspended {
      await Task.yield()
    }
    let sawLoading = loadingModel.loading && hold.suspended
    let loadingImage = sawLoading ? try listenerPaneImage(loadingModel) : Data()
    hold.finishLoad()
    if hold.suspended {
      await loadingTask.value
    } else {
      loadingTask.cancel()
    }
    #expect(sawLoading)
    #expect(!loadingImage.isEmpty)
    #expect(loadingModel.loading == false)

    let emptyModel = ShaarEventListenersModel(
      target: listenerTarget(), transport: ShaarEventListenersPendingTransport())
    await emptyModel.load(nodeID: 8, ancestors: [])
    #expect(emptyModel.nodeID == 8)
    #expect(emptyModel.visibleGroups.isEmpty)
    let emptyImage = try listenerPaneImage(emptyModel)
    await emptyModel.load(nodeID: nil, ancestors: [])
    #expect(emptyModel.nodeID == nil)
    let cleared = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/cleared")!)
    emptyModel.updateTarget(cleared)
    #expect(emptyModel.target == cleared)
    #expect(emptyModel.listeners.isEmpty)

    let failedModel = ShaarEventListenersModel(
      target: listenerTarget(), transport: ListenerRejectTransport())
    await failedModel.load(nodeID: 4, ancestors: [])
    #expect(failedModel.listeners.isEmpty)
    #expect(failedModel.failure == "Event listeners need engine support")
    let failedImage = try listenerPaneImage(failedModel)

    let onceModel = ShaarEventListenersModel(
      target: listenerTarget(), transport: ListenerFailEditTransport())
    await onceModel.load(nodeID: 8, ancestors: [])
    let once = try #require(onceModel.listeners.first)
    #expect(once.once == true)
    #expect(once.source == nil)
    await onceModel.togglePassive(once.id)
    #expect(onceModel.listeners.first?.passive == false)
    await onceModel.remove(once.id)
    #expect(onceModel.listeners.count == 1)
    #expect(onceModel.failure == "Event listeners need engine support")
    let onceImage = try listenerPaneImage(onceModel)

    #expect(!emptyImage.isEmpty)
    #expect(!failedImage.isEmpty)
    #expect(!onceImage.isEmpty)
    #expect(emptyImage != failedImage)
    #expect(failedImage != onceImage)
  }

  @Test func writesOffscreenEvidenceWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_EVENT_LISTENERS_CAPTURE"] == "1" else {
      return
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1272")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = ShaarEventListenersModel(
      target: listenerTarget(), transport: ShaarEventListenerFixture())
    await model.load(nodeID: 8, ancestors: [3])
    for scheme in [ColorScheme.light, ColorScheme.dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let empty = ShaarEventListenersModel(
        target: listenerTarget(), transport: ShaarEventListenersPendingTransport())
      try captureListeners(
        ShaarEventListenersPane(model: empty), named: "before-empty-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      model.includeAncestors = true
      try captureListeners(
        ShaarEventListenersPane(model: model), named: "after-listeners-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      model.includeAncestors = false
      try captureListeners(
        ShaarEventListenersPane(model: model), named: "after-ancestors-off-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
    }
    #expect(NSApp.keyWindow === previous)
  }
}

@MainActor private func listenerPaneImage(_ model: ShaarEventListenersModel) throws -> Data {
  try VisualCapture.pngOffscreen(
    ShaarEventListenersPane(model: model), size: NSSize(width: 520, height: 360))
}

@MainActor private func captureListeners(
  _ view: some View, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
  root: URL
) throws {
  let image = try VisualCapture.renderOffscreen(
    view.frame(width: 520, height: 360).environment(\.colorScheme, scheme),
    size: NSSize(width: 520, height: 360), appearance: appearance,
    to: root.appending(path: "\(name).png"))
  #expect(image.pixelsWide == 520)
  #expect(image.pixelsHigh == 360)
}

private func listenerTarget() -> SiteControlTarget {
  SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test")!)
}

@MainActor private final class ListenerCallLog {
  var entries: [(String, [String: Any])] = []
  var resolves = 0
  var rebound: [Int] = []
}

@MainActor private final class ListenerHoldTransport: ShaarEventListenersTransport {
  private var releaseLoad: CheckedContinuation<Void, Never>?
  private(set) var suspended = false

  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    await withCheckedContinuation { continuation in
      releaseLoad = continuation
      suspended = true
    }
    return []
  }

  func finishLoad() {
    releaseLoad?.resume()
    releaseLoad = nil
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {}

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {}

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
  }
}

@MainActor private struct ListenerRejectTransport: ShaarEventListenersTransport {
  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    throw ShaarEventListenersUnavailable()
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {
    throw ShaarEventListenersUnavailable()
  }

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }
}

@MainActor private struct ListenerFailEditTransport: ShaarEventListenersTransport {
  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    [
      ShaarEventListener(
        id: "8|submit|0", type: "submit", nodeID: 8, onAncestor: false, capture: false,
        passive: false, once: true, source: nil, handlerObjectID: nil)
    ]
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {
    throw ShaarEventListenersUnavailable()
  }

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
    throw ShaarEventListenersUnavailable()
  }
}
