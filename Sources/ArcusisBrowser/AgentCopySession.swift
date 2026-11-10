// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Observation

struct AgentCopyStamp: Equatable {
  var href: String
  var timeOrigin: Double
  var tabID: UUID
}

@MainActor @Observable
final class AgentCopySession {
  private(set) var scope: AgentCopyScope = .page
  private(set) var busy = false
  private(set) var failure: String?
  private(set) var notice: String?
  private(set) var packet: AgentCopyBuilt?
  private(set) var didCopy = false
  private(set) var bridgeInvoked = false
  private(set) var bridgeEnabled = false
  private(set) var bridgeError: String?
  var pasteboard: NSPasteboard = .general
  var preferredSelector: String?

  @ObservationIgnored private weak var store: BrowserStore?
  @ObservationIgnored private var ticket = 0
  @ObservationIgnored private var stamp: AgentCopyStamp?
  @ObservationIgnored private var heldBridge: AgentBridgeModel?
  @ObservationIgnored private var bridgeOwnership = BridgeOwnership.none
  @ObservationIgnored private var didShutdown = false

  private enum BridgeOwnership { case none, created, enabledShared }

  init(store: BrowserStore, unavailable: Bool = false) {
    self.store = store
    if unavailable { failure = ShellL10n.string("Choose a web page first.") }
  }

  var panelState: AgentCopyPanelState {
    let built = packet
    let bytes = built?.bytes
    return AgentCopyPanelState(
      scope: scope,
      busy: busy,
      sizeText: bytes.map(AgentCopySize.text(for:)) ?? "",
      byteCount: bytes,
      failure: failure,
      notice: notice,
      canCopy: built != nil && !busy && AgentCopyGuard.accepts(built?.markdown ?? ""),
      preview: previewText(built?.markdown ?? ""),
      ruleCount: built?.ruleCount ?? 0,
      errorCount: built?.errorCount ?? 0,
      requestCount: built?.requestCount ?? 0,
      consoleRecording: built?.consoleRecording ?? false,
      stylesOmitted: built?.stylesOmitted ?? false,
      source: built?.source ?? "",
      screenshotBytes: built?.screenshotBytes ?? 0)
  }

  func setScope(_ next: AgentCopyScope) {
    scope = next
    rebuild()
  }

  func rebuild() {
    guard !didShutdown else { return }
    ticket += 1
    let current = ticket
    busy = true
    failure = nil
    notice = nil
    packet = nil
    stamp = nil
    Task { await collect(current) }
  }

  func copy() {
    Task { await copyNow() }
  }

  func handToAgent() {
    Task { await handoffNow() }
  }

  func shutdown() async {
    guard !didShutdown else { return }
    didShutdown = true
    ticket += 1
    busy = false
    packet = nil
    let model = heldBridge
    let ownership = bridgeOwnership
    heldBridge = nil
    bridgeOwnership = .none
    await settle(model, ownership: ownership)
  }

  func installDiagnostics() async throws {
    let source = InspectorDiagnosticsScript.install.replacingOccurrences(
      of: "__SHAAR_DIAGNOSTICS_OWNER__", with: "shaar-agent-copy")
    _ = try await evaluatePage(source)
  }

  func evaluatePage(_ expression: String) async throws -> Any? {
    guard let target = currentTarget(), let connection = makeConnection(), connection.begin(target)
    else {
      throw InspectorFailure(ShellL10n.string("Choose a web page first."))
    }
    return try await evaluate(expression, connection: connection, target: target)
  }

  func copyNow() async -> Bool {
    guard let packet, !busy else { return false }
    guard await pageStillMatches() else {
      failure = ShellL10n.string("The page changed. Build the packet again.")
      notice = nil
      return false
    }
    guard AgentCopyGuard.accepts(packet.markdown) else {
      failure = ShellL10n.string("The packet still contained a secret, so it was not copied.")
      notice = nil
      return false
    }
    do {
      try InspectorAICopyModel.write(packet.markdown, png: packet.png, to: pasteboard)
      didCopy = true
      notice = ShellL10n.string("The packet is on the clipboard.")
      failure = nil
      return true
    } catch {
      failure = AgentCopySecrets.scrub(error.localizedDescription)
      return false
    }
  }

  func handoffNow() async {
    let copied = await copyNow()
    guard copied else { return }
    if store?.privatePage != nil {
      bridgeError = ShellL10n.string("The agent bridge is not available in a private window.")
      failure = bridgeError
      notice = ShellL10n.string("The packet is on the clipboard.")
      return
    }
    guard let model = bridgeModel() else {
      bridgeError = ShellL10n.string("The agent packet is unavailable.")
      failure = bridgeError
      notice = ShellL10n.string("The packet is on the clipboard.")
      return
    }
    bridgeInvoked = true
    if model.status.enabled {
      model.refresh()
    } else {
      model.enable()
      await waitUntilIdle(model)
    }
    bridgeEnabled = model.status.enabled
    if let error = model.failure {
      bridgeError = AgentCopySecrets.scrub(error)
      failure = bridgeError
      notice = ShellL10n.string("The packet is on the clipboard.")
      return
    }
    bridgeError = nil
    failure = nil
    if model.status.enabled {
      notice = ShellL10n.string("The packet is on the clipboard. The agent bridge is on.")
    } else {
      notice = ShellL10n.string("The packet is on the clipboard.")
    }
  }

  private func collect(_ current: Int) async {
    defer { if ticket == current { busy = false } }
    let token = AgentCopyToken.make()
    do {
      let built = try await withCleanup(token: token, current: current) {
        try await buildPacket(token: token, current: current)
      }
      guard ticket == current else { return }
      packet = built
      failure = nil
    } catch is CancellationError {
      return
    } catch let error as AgentCopyPageFailure {
      guard ticket == current else { return }
      failure = error.message
    } catch {
      guard ticket == current else { return }
      failure = AgentCopySecrets.scrub(error.localizedDescription)
    }
  }

  private func buildPacket(token: String, current: Int) async throws -> AgentCopyBuilt {
    guard ticket == current else { throw CancellationError() }
    guard let target = currentTarget(), let connection = makeConnection(), connection.begin(target)
    else {
      throw AgentCopyPageFailure(ShellL10n.string("Choose a web page first."))
    }
    let before = try await readStamp(connection: connection, target: target)
    guard before.tabID == target.tabID else { throw CancellationError() }
    _ = try? await connection.call("DOM.enable", params: [:], target: target)
    _ = try? await connection.call("DOM.getDocument", params: ["depth": 0], target: target)
    _ = try? await connection.call("CSS.enable", params: [:], target: target)
    guard ticket == current else { throw CancellationError() }
    let value = try await evaluate(
      collectExpression(token: token), connection: connection, target: target)
    guard let page = value as? [String: Any] else {
      throw InspectorFailure(ShellL10n.string("The agent packet is unavailable."))
    }
    if (page["ok"] as? Bool) == false {
      throw AgentCopyPageFailure(message(for: stringValue(page["reason"])))
    }
    let after = try await readStamp(connection: connection, target: target)
    guard stampsMatch(before, after), ticket == current else {
      throw AgentCopyPageFailure(ShellL10n.string("The page changed. Build the packet again."))
    }
    let parsed = AgentCopyPage.parse(page)
    let styles = try await matchedStyles(connection: connection, target: target, token: token)
    guard ticket == current else { throw CancellationError() }
    let png = await screenshot(parsed.rect, scope: scope, connection: connection, target: target)
    let input = AgentCopyPayload.make(
      page: parsed, styles: styles, screenshotBytes: png?.count ?? 0)
    let script = try AgentCopyScript.source()
    let built = try AgentCopyEngine.build(script: script, input: input.object, png: png)
    guard AgentCopyGuard.accepts(built.markdown) else {
      throw AgentCopyPageFailure(
        ShellL10n.string("The packet still contained a secret, so it was not copied."))
    }
    stamp = before
    return built
  }

  private func matchedStyles(
    connection: InspectorConnection, target: SiteControlTarget, token: String
  ) async throws -> AgentCopyStyleResult {
    let node = await nodeID(token: token, connection: connection, target: target)
    let styles = try? await stylesForNode(node, connection: connection, target: target)
    await releaseNodeGroup(token: token, connection: connection, target: target)
    return AgentCopyStyles.prepare(styles ?? [:])
  }

  /// `DOM.querySelector` is outside the inspector allow-list. The document has to
  /// be requested before `requestNode`, matching the Inspector session.
  private func nodeID(
    token: String, connection: InspectorConnection, target: SiteControlTarget
  ) async -> Int? {
    guard AgentCopyToken.isMarker(token) else { return nil }
    let expression = "document.querySelector('[data-shaar-agent=\"\(token)\"]')"
    guard
      let evaluated = try? await connection.call(
        "Runtime.evaluate",
        params: ["expression": expression, "objectGroup": AgentCopyToken.group(token)],
        target: target),
      evaluated["exceptionDetails"] == nil,
      let remote = evaluated["result"] as? [String: Any],
      let objectID = remote["objectId"] as? String, !objectID.isEmpty
    else { return nil }
    let requested = try? await connection.call(
      "DOM.requestNode", params: ["objectId": objectID], target: target)
    let nodeID = AgentCopyNumbers.int(requested?["nodeId"])
    guard nodeID > 0 else { return nil }
    return nodeID
  }

  private func stylesForNode(
    _ nodeID: Int?, connection: InspectorConnection, target: SiteControlTarget
  ) async throws -> [String: Any]? {
    guard let nodeID, nodeID > 0 else { return nil }
    return try await connection.call(
      "CSS.getMatchedStylesForNode", params: ["nodeId": nodeID], target: target)
  }

  private func releaseNodeGroup(
    token: String, connection: InspectorConnection, target: SiteControlTarget
  ) async {
    guard AgentCopyToken.isMarker(token) else { return }
    _ = try? await connection.call(
      "Runtime.releaseObjectGroup",
      params: ["objectGroup": AgentCopyToken.group(token)],
      target: target)
  }

  private func screenshot(
    _ rect: AgentCopyRect, scope: AgentCopyScope, connection: InspectorConnection,
    target: SiteControlTarget
  ) async -> Data? {
    guard AgentCopyClip.usable(rect) else { return nil }
    let beyond = scope == .element
    let params: [String: Any] = [
      "format": "png",
      "captureBeyondViewport": beyond,
      "clip": [
        "x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height, "scale": 1,
      ],
    ]
    guard
      let result = try? await connection.call(
        "Page.captureScreenshot", params: params, target: target),
      let encoded = result["data"] as? String, encoded.count <= 1_500_000,
      let data = Data(base64Encoded: encoded),
      data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    else { return nil }
    return data
  }

  private func withCleanup(
    token: String, current: Int, _ work: () async throws -> AgentCopyBuilt
  ) async throws -> AgentCopyBuilt {
    do {
      let built = try await work()
      guard ticket == current else { throw CancellationError() }
      await cleanup(token)
      return built
    } catch {
      await cleanup(token)
      throw error
    }
  }

  private func cleanup(_ token: String) async {
    guard let target = currentTarget(), let connection = makeConnection(), connection.begin(target)
    else { return }
    _ = try? await evaluate(AgentCopyToken.cleanup(token), connection: connection, target: target)
  }

  private func pageStillMatches() async -> Bool {
    guard let stamp, let target = currentTarget(), target.tabID == stamp.tabID,
      let connection = makeConnection(), connection.begin(target)
    else { return false }
    guard let next = try? await readStamp(connection: connection, target: target) else {
      return false
    }
    return stampsMatch(stamp, next)
  }

  private func readStamp(connection: InspectorConnection, target: SiteControlTarget) async throws
    -> AgentCopyStamp
  {
    let expression = "({href:String(location.href),timeOrigin:performance.timeOrigin})"
    let value = try await evaluate(expression, connection: connection, target: target)
    guard
      let object = value as? [String: Any],
      let href = object["href"] as? String, !href.isEmpty,
      let timeOrigin = AgentCopyNumbers.double(object["timeOrigin"])
    else {
      throw AgentCopyPageFailure(ShellL10n.string("The page changed. Build the packet again."))
    }
    return AgentCopyStamp(href: href, timeOrigin: timeOrigin, tabID: target.tabID)
  }

  private func stampsMatch(_ before: AgentCopyStamp, _ after: AgentCopyStamp) -> Bool {
    before.tabID == after.tabID && before.href == after.href
      && abs(before.timeOrigin - after.timeOrigin) < 0.5
  }

  private func evaluate(
    _ expression: String, connection: InspectorConnection, target: SiteControlTarget
  ) async throws -> Any? {
    let result = try await connection.call(
      "Runtime.evaluate",
      params: ["expression": expression, "returnByValue": true, "awaitPromise": true],
      target: target)
    if let details = result["exceptionDetails"] {
      let detail = AgentCopySecrets.scrub(stringValue((details as? [String: Any])?["text"]))
      let message = ShellL10n.string("The page could not build the agent packet.")
      throw InspectorFailure(detail.isEmpty ? message : message + " " + detail)
    }
    return (result["result"] as? [String: Any])?["value"]
  }

  private func collectExpression(token: String) throws -> String {
    let script = try AgentCopyScript.source()
    let options: [String: String] = [
      "scope": scope.rawValue,
      "token": token,
      "selector": AgentCopySelector.accepted(preferredSelector) ?? "",
    ]
    let data = try JSONSerialization.data(withJSONObject: options)
    let literal = String(data: data, encoding: .utf8) ?? "{}"
    return script + "\n;ShaarAgentCopy.collect(" + literal + ")"
  }

  private func currentTarget() -> SiteControlTarget? { store?.agentPacketTarget }

  private func makeConnection() -> InspectorConnection? {
    guard let store else { return nil }
    if let page = store.privatePage { return InspectorConnection(session: page) }
    if let engine = store.engine { return InspectorConnection(engine: engine) }
    return nil
  }

  private func bridgeModel() -> AgentBridgeModel? {
    if let heldBridge { return heldBridge }
    guard let store, store.privatePage == nil, let engine = store.engine,
      let target = currentTarget()
    else { return nil }
    if let existing = engine.developerModels[target.tabID]?.agentBridge {
      heldBridge = existing
      if !existing.status.enabled { bridgeOwnership = .enabledShared }
      return existing
    }
    let model = AgentBridgeModel(target: target) { [weak engine] operation, target, completion in
      guard let engine, !engine.isClosed else {
        completion(nil, AgentBridgeFailure.invalidReply)
        return
      }
      engine.runtime.agentBridgeRequest(
        UInt(operation.rawValue), forTabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: engine.windowID,
        completion: completion)
    }
    heldBridge = model
    bridgeOwnership = .created
    return model
  }

  private func waitUntilIdle(_ model: AgentBridgeModel) async {
    for _ in 0..<50 where model.busy {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private func settle(_ model: AgentBridgeModel?, ownership: BridgeOwnership) async {
    guard let model else { return }
    switch ownership {
    case .none:
      return
    case .created:
      model.close()
      for _ in 0..<50 where model.busy || model.status.enabled || model.revocationUnconfirmed {
        try? await Task.sleep(for: .milliseconds(100))
      }
    case .enabledShared:
      model.disable()
      for _ in 0..<50 where model.busy {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func message(for reason: String) -> String {
    if reason == "no-selection" { return ShellL10n.string("No element is selected.") }
    return ShellL10n.string("Choose a web page first.")
  }

  private func previewText(_ markdown: String) -> String {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
    return lines.joined(separator: "\n")
  }
}

private struct AgentCopyPageFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

private struct AgentCopyRect: Equatable {
  var x = 0.0
  var y = 0.0
  var width = 0.0
  var height = 0.0
}

private struct AgentCopyPage {
  var url: String
  var html: String
  var source: String
  var scope: String
  var rect: AgentCopyRect
  var consoleErrors: [String]
  var failedRequests: [[String: Any]]
  var consoleRecording: Bool

  static func parse(_ value: [String: Any]) -> AgentCopyPage {
    let rect = value["rect"] as? [String: Any] ?? [:]
    return AgentCopyPage(
      url: stringValue(value["url"]),
      html: stringValue(value["html"]),
      source: stringValue(value["source"]),
      scope: stringValue(value["scope"]),
      rect: AgentCopyRect(
        x: AgentCopyNumbers.double(rect["x"]) ?? 0,
        y: AgentCopyNumbers.double(rect["y"]) ?? 0,
        width: AgentCopyNumbers.double(rect["width"]) ?? 0,
        height: AgentCopyNumbers.double(rect["height"]) ?? 0),
      consoleErrors: strings(value["consoleErrors"], limit: 8),
      failedRequests: requests(value["failedRequests"]),
      consoleRecording: AgentCopyNumbers.bool(value["consoleRecording"]))
  }

  private static func strings(_ value: Any?, limit: Int) -> [String] {
    guard let rows = value as? [Any] else { return [] }
    var result: [String] = []
    for row in rows {
      result.append(stringValue(row))
      if result.count == limit { break }
    }
    return result
  }

  private static func requests(_ value: Any?) -> [[String: Any]] {
    guard let rows = value as? [Any] else { return [] }
    var result: [[String: Any]] = []
    for row in rows {
      guard let item = row as? [String: Any] else { continue }
      result.append([
        "method": stringValue(item["method"]),
        "url": stringValue(item["url"]),
        "status": AgentCopyNumbers.int(item["status"]),
        "requestHeaders": headerPairs(item["requestHeaders"] ?? item["headers"]),
        "responseHeaders": headerPairs(item["responseHeaders"]),
      ])
      if result.count == 8 { break }
    }
    return result
  }

  private static func headerPairs(_ value: Any?) -> [[String: String]] {
    guard let rows = value as? [Any] else { return [] }
    var result: [[String: String]] = []
    for row in rows {
      guard let item = row as? [String: Any] else { continue }
      let name = stringValue(item["name"])
      if name.isEmpty { continue }
      result.append(["name": name, "value": stringValue(item["value"])])
      if result.count == 8 { break }
    }
    return result
  }
}

private func stringValue(_ value: Any?) -> String {
  let text: String
  if let value = value as? String {
    text = value
  } else if let value = value as? NSNumber {
    text = value.stringValue
  } else {
    text = ""
  }
  if text.count <= 4_000 { return text }
  return String(text.prefix(4_000))
}

private struct AgentCopyStyleResult {
  var styles: [String: Any]
  var omitted: Bool
}

private enum AgentCopyStyles {
  static func prepare(_ value: [String: Any]) -> AgentCopyStyleResult {
    let slim = slimmed(value)
    if jsonCount(slim) <= 160_000, let object = slim as? [String: Any] {
      return AgentCopyStyleResult(styles: object, omitted: false)
    }
    return AgentCopyStyleResult(styles: [:], omitted: true)
  }

  private static func slimmed(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
      var copy: [String: Any] = [:]
      for (key, item) in dictionary where key != "cssText" && key != "range" {
        copy[key] = slimmed(item)
      }
      return copy
    }
    if let list = value as? [Any] { return list.map(slimmed) }
    return value
  }

  private static func jsonCount(_ value: Any) -> Int {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return Int.max }
    return data.count
  }
}

private enum AgentCopyPayload {
  static func make(page: AgentCopyPage, styles: AgentCopyStyleResult, screenshotBytes: Int) -> (
    object: [String: Any], omitted: Bool
  ) {
    var omitted = styles.omitted
    var object = payload(
      page: page, styles: styles.styles, omitted: omitted, bytes: screenshotBytes)
    if jsonCount(object) > 200_000 {
      omitted = true
      object = payload(page: page, styles: [:], omitted: true, bytes: screenshotBytes)
    }
    return (object, omitted)
  }

  private static func payload(
    page: AgentCopyPage, styles: [String: Any], omitted: Bool, bytes: Int
  ) -> [String: Any] {
    [
      "page": [
        "url": page.url,
        "html": page.html,
        "source": page.source,
        "scope": page.scope,
        "consoleErrors": page.consoleErrors,
        "failedRequests": page.failedRequests,
        "consoleRecording": page.consoleRecording,
      ],
      "matchedStyles": styles,
      "stylesOmitted": omitted,
      "screenshotBytes": bytes,
    ]
  }

  private static func jsonCount(_ value: Any) -> Int {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return Int.max }
    return data.count
  }
}

private enum AgentCopyClip {
  static func usable(_ rect: AgentCopyRect) -> Bool {
    let values = [rect.x, rect.y, rect.width, rect.height]
    guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return false }
    if rect.width > 4_000 || rect.height > 4_000 { return false }
    return rect.width * rect.height * 4 <= 8_000_000
  }
}

private enum AgentCopyNumbers {
  static func int(_ value: Any?) -> Int {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    return 0
  }

  static func double(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
  }

  static func bool(_ value: Any?) -> Bool {
    if let number = value as? Bool { return number }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }
}

private enum AgentCopyToken {
  static func isMarker(_ token: String) -> Bool {
    token.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil
  }

  static func group(_ token: String) -> String {
    "shaar-agent-copy-\(token)"
  }

  static func make() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  static func cleanup(_ token: String) -> String {
    guard token.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
      return "delete globalThis.ShaarAgentCopy; true"
    }
    return """
      (() => {
        const node = document.querySelector('[data-shaar-agent="\(token)"]');
        if (node) node.removeAttribute('data-shaar-agent');
        delete globalThis.ShaarAgentCopy;
        return true;
      })()
      """
  }
}

extension BrowserStore {
  var agentPacketTarget: SiteControlTarget? {
    if let target = privatePage?.inspectorTarget, NavigationInput.isWebURL(target.url) {
      return target
    }
    if let target = engine?.siteControlTarget, NavigationInput.isWebURL(target.url) {
      return target
    }
    return nil
  }

  func presentAgentPacket() {
    dismissCommand()
    let previous = agentCopy
    agentCopy = nil
    Task { await previous?.shutdown() }
    guard agentPacketTarget != nil else {
      agentCopy = AgentCopySession(store: self, unavailable: true)
      return
    }
    let session = AgentCopySession(store: self)
    agentCopy = session
    session.rebuild()
  }

  func dismissAgentPacket() {
    let previous = agentCopy
    agentCopy = nil
    Task { await previous?.shutdown() }
  }
}
