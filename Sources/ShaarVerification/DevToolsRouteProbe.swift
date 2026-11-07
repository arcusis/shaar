// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

/// Runs the real DevTools frontend requests in a disposable hidden Shaar window.
@MainActor
final class DevToolsRouteProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var requests: [String] = []

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let previousRequestHandler = engine.events.onDevToolsOpenURLRequest
    engine.events.onDevToolsOpenURLRequest = { [weak self] payload in
      self?.acceptRequestedURL(payload)
    }
    defer { engine.events.onDevToolsOpenURLRequest = previousRequestHandler }
    let returningTo = store.session.selectedSpaceID
    try expect(
      store.createSpace(
        name: "DevTools Route", sharingProfile: store.session.selectedSpace.profileID,
        tint: .ocean), "create an isolated DevTools Space")
    let space = store.session.selectedSpaceID
    store.perform(.open(fixture.appending(path: "developer-tools")))
    guard let tab = store.session.selectedPage?.tab.id else { throw Failure("No fixture tab") }
    let identity = tab.uuidString
    let runtime = engine.runtime
    try await wait("fixture page loads") {
      engine.liveTabs.contains(tab) && engine.pages[tab]?.loading == false
        && runtime.view(forTabID: identity)?.superview != nil
    }
    guard let target = engine.siteControlTarget, target.tabID == tab else {
      throw Failure("No selected target")
    }
    try await verifyFrameworkDevTools(profileID: target.profileID.uuidString)
    try expect(engine.openChromiumDeveloperTools(for: tab), "open selected tab DevTools")
    try await wait("DevTools docks in the hidden Shaar host") {
      let audit = self.dockAudit(identity)
      return audit?["open"] as? Bool == true && audit?["sameContainer"] as? Bool == true
        && audit?["gap"] as? Double == 0
        && audit?["allWindowsHidden"] as? Bool == true
    }
    let nativeWindowCount = NSApp.windows.count
    let tabCount = store.session.selectedSpace.tabs.count
    try expect(
      await route(
        tab: identity, operation: 1090,
        payload: [
          "schemaVersion": 1,
          "url": "https://github.com/ChromeDevTools/chrome-devtools-mcp",
        ]),
      "DevTools accepts the MCP URL request")
    try await wait("MCP URL opens in an app-owned tab") {
      store.session.selectedSpace.tabs.count == tabCount + 1
        && store.session.selectedPage?.tab.url.absoluteString
          == "https://github.com/ChromeDevTools/chrome-devtools-mcp"
    }
    try expect(hiddenWindowCountIs(nativeWindowCount), "MCP URL creates no Chromium window")
    if let opened = store.session.selectedPage?.tab.id { store.closeTab(opened) }
    store.perform(.tab(space: space, tab: tab))
    try await wait("closing the Get MCP tab leaves DevTools and the browser alive") {
      engine.liveTabs.contains(tab) && dockAudit(identity)?["open"] as? Bool == true
    }
    var nodePayload: [String: Any] = ["schemaVersion": 1]
    if let portValue = ProcessInfo.processInfo.environment["SHAAR_NODE_INSPECTOR_PORT"] {
      guard let port = Int(portValue), (1...65535).contains(port) else {
        throw Failure("Invalid local Node inspector port")
      }
      nodePayload["nodeInspectPort"] = port
    }
    try expect(
      await route(
        tab: identity, operation: nodePayload["nodeInspectPort"] == nil ? 1091 : 1094,
        payload: nodePayload),
      "Node discovery request reaches the engine")
    try await wait("Node discovery opens in an app-owned tab") {
      store.session.selectedPage?.tab.url.path == "/bundled/node_app.html"
        && store.session.selectedSpace.tabs.count == tabCount + 1
    }
    guard let nodeTab = store.session.selectedPage?.tab.id else {
      throw Failure("No Node frontend tab")
    }
    try await wait("Node frontend tab has a native view") {
      runtime.view(forTabID: nodeTab.uuidString) != nil
    }
    if nodePayload["nodeInspectPort"] != nil {
      try await wait("Node frontend attaches to local inspector target") {
        await self.nodeFrontendTitle(nodeTab)?.contains("shaar-node-inspect-fixture.js") == true
      }
      checks.append("Node frontend attaches to a live local node --inspect target")
    }
    try expect(
      await route(
        tab: nodeTab.uuidString, operation: 1092,
        payload: ["schemaVersion": 1]),
      "Node frontend retains its agent host")
    try expect(hiddenWindowCountIs(nativeWindowCount), "Node creates no Chromium window")
    store.closeTab(nodeTab)
    store.perform(.tab(space: space, tab: tab))
    try await wait("closing Node frontend leaves the engine alive") {
      engine.liveTabs.contains(tab) && dockAudit(identity)?["open"] as? Bool == true
    }
    try expect(runtime.closeDevTools(forTabID: identity), "close selected tab DevTools")
    try await wait("DevTools close leaves the page alive") {
      engine.liveTabs.contains(tab) && runtime.devToolsView(forTabID: identity) == nil
    }
    try await verifyAgentBridge(tabID: identity, target: target)
    store.perform(.space(returningTo))
    try expect(store.removeSpace(space), "close the isolated DevTools Space")
  }

  private func dockAudit(_ tabID: String) -> [AnyHashable: Any]? {
    ARCProbeDevToolsDockAudit(engine.runtime, tabID, engine.windowID, nil)
  }

  private func nodeFrontendTitle(_ tabID: UUID) async -> String? {
    await withCheckedContinuation { continuation in
      engine.runtime.evaluate(inTabID: tabID.uuidString, script: "document.title") {
        continuation.resume(returning: $0)
      }
    }
  }

  private func hiddenWindowCountIs(_ count: Int) -> Bool {
    NSApp.windows.count == count && NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private func acceptRequestedURL(_ payload: [String: Any]) {
    guard let request = DevToolsOpenURLRequest(payload), request.contextID == nil,
      request.windowID == engine.windowID, engine.liveTabs.contains(request.tabID),
      engine.runtime.windowID(forTabID: request.tabID.uuidString) == request.windowID
    else { return }
    requests.append(request.url.absoluteString)
    _ = store.openDevToolsRequestedTab(
      request.url, sourceTabID: request.tabID, profileID: request.profileID)
  }

  private func route(tab: String, operation: Int, payload: [String: Any]) async -> Bool {
    await withCheckedContinuation { continuation in
      engine.runtime.probeDevToolsRoute(inTabID: tab, operation: operation, payload: payload) {
        continuation.resume(returning: $0)
      }
    }
  }

  private func agentRequest(
    operation: Int, tabID: String, target: SiteControlTarget
  ) async -> (Data?, String?) {
    await withCheckedContinuation { continuation in
      engine.runtime.agentBridgeRequest(
        UInt(operation), forTabID: tabID, profileID: target.profileID.uuidString,
        windowID: engine.windowID
      ) { value, error in
        let data = value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        continuation.resume(returning: (data, error?.localizedDescription))
      }
    }
  }

  private func verifyFrameworkDevTools(profileID: String) async throws {
    guard let runtime = engine.runtime as? ARCShaarRuntime else {
      throw Failure("Framework DevTools audit needs the Shaar runtime")
    }
    let (data, failure): (Data?, String?) = await withCheckedContinuation { continuation in
      runtime.probeFrameworkDevTools(forProfileID: profileID) { value, error in
        let data = value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        continuation.resume(returning: (data, error?.localizedDescription))
      }
    }
    guard failure == nil, let data,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let components = result["components"] as? [[String: Any]], components.count == 3,
      components.allSatisfy({
        $0["registered"] as? Bool == true && $0["enabled"] as? Bool == true
      })
    else {
      let detail = failure ?? String(data: data ?? Data(), encoding: .utf8) ?? "no result"
      throw Failure("Framework DevTools native audit failed: \(detail)")
    }
    checks.append("three bundled framework DevTools register and enable in the regular profile")
  }

  private func verifyAgentBridge(tabID: String, target: SiteControlTarget) async throws {
    let otherTabID = try await prepareAgentBridgePages(grantedTabID: tabID, target: target)
    defer { closeProbeTab(otherTabID) }
    let (enabledData, error) = await agentRequest(operation: 1005, tabID: tabID, target: target)
    guard error == nil, let enabledData,
      let enabled = try JSONSerialization.jsonObject(with: enabledData) as? [String: Any],
      enabled["enabled"] as? Bool == true,
      let token = enabled["token"] as? String, token.count == 43,
      let endpoint = enabled["wsEndpoint"] as? String,
      let url = URL(string: endpoint), url.host() == "127.0.0.1"
    else {
      throw Failure(
        "Agent bridge did not return a scoped loopback grant: \(String(describing: error))")
    }
    checks.append("agent bridge grants only the selected regular tab on loopback")
    defer {
      Task { _ = await self.agentRequest(operation: 1006, tabID: tabID, target: target) }
    }
    let session = URLSession(
      configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return config
      }())
    defer { session.invalidateAndCancel() }
    var discovery = URLRequest(url: URL(string: "http://127.0.0.1:\(url.port ?? 0)/json")!)
    discovery.timeoutInterval = 5
    let (_, response) = try await session.data(for: discovery)
    let discoveryStatus = (response as? HTTPURLResponse)?.statusCode
    try expect(
      discoveryStatus == 403 || discoveryStatus == 404,
      "agent bridge hides unauthenticated discovery (HTTP \(discoveryStatus ?? -1))")
    var wrong = URLRequest(url: url)
    wrong.setValue(
      "Bearer \(String(repeating: "A", count: 43))", forHTTPHeaderField: "Authorization")
    let rejected = session.webSocketTask(with: wrong)
    rejected.resume()
    do {
      try await rejected.send(.string("{\"id\":1,\"method\":\"Target.getTargets\"}"))
      _ = try await rejected.receive()
      throw Failure("Agent bridge accepted a wrong token")
    } catch is Failure {
      throw Failure("Agent bridge accepted a wrong token")
    } catch {
      checks.append("agent bridge rejects the wrong bearer token")
    }
    rejected.cancel(with: .normalClosure, reason: nil)
    let missing = session.webSocketTask(with: url)
    missing.resume()
    do {
      try await missing.send(.string("{\"id\":1,\"method\":\"Target.getTargets\"}"))
      _ = try await missing.receive()
      throw Failure("Agent bridge accepted a missing token")
    } catch is Failure {
      throw Failure("Agent bridge accepted a missing token")
    } catch {
      checks.append("agent bridge rejects a missing bearer token")
    }
    missing.cancel(with: .normalClosure, reason: nil)
    var authorized = URLRequest(url: url)
    authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let socket = session.webSocketTask(with: authorized)
    socket.resume()
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    try await socket.send(.string("{\"id\":1,\"method\":\"Target.getTargets\"}"))
    let targets = try await socket.receive()
    guard case .string(let targetsJSON) = targets,
      let targetsData = targetsJSON.data(using: .utf8),
      let targetsObject = try JSONSerialization.jsonObject(with: targetsData) as? [String: Any],
      let result = targetsObject["result"] as? [String: Any],
      let targetInfos = result["targetInfos"] as? [[String: Any]], targetInfos.count == 1,
      let targetID = targetInfos[0]["targetId"] as? String,
      let targetURL = targetInfos[0]["url"] as? String,
      targetURL.contains("/account/agent-bridge"), !targetURL.contains("agent-bridge-other")
    else { throw Failure("Agent bridge did not expose exactly the granted tab") }
    checks.append("agent bridge discovers exactly one owned tab")
    try await socket.send(
      .string(
        "{\"id\":2,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"foreign-target\",\"flatten\":true}}"
      ))
    let foreign = try await socket.receive()
    guard case .string(let foreignJSON) = foreign, foreignJSON.contains("error") else {
      throw Failure("Agent bridge accepted a foreign target")
    }
    checks.append("agent bridge rejects a foreign target")
    try await socket.send(.string("{\"id\":3,\"method\":\"Input.dispatchMouseEvent\"}"))
    let input = try await socket.receive()
    guard case .string(let inputJSON) = input, inputJSON.contains("error") else {
      throw Failure("Agent bridge accepted input injection")
    }
    checks.append("agent bridge rejects input injection")
    try await socket.send(
      .string(
        "{\"id\":4,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"\(targetID)\",\"flatten\":true}}"
      ))
    let attached = try await socket.receive()
    guard case .string(let attachedJSON) = attached,
      let attachedData = attachedJSON.data(using: .utf8),
      let attachedObject = try JSONSerialization.jsonObject(with: attachedData) as? [String: Any],
      let attachedResult = attachedObject["result"] as? [String: Any],
      let pageSession = attachedResult["sessionId"] as? String, !pageSession.isEmpty
    else { throw Failure("Agent bridge could not attach to its owned tab") }
    checks.append("agent bridge attaches to its owned tab")
    let client = ScopedAgentClient(task: socket, nextID: 5)
    try await readGrantedTab(client, session: pageSession)
    try await refuseUngrantedReads(client)
    try await expectOtherTabDisabled(otherTabID, target: target)
    var listed = false
    for _ in 0..<20 {
      if await connectionCount(tabID: tabID, target: target) >= 1 {
        listed = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    try expect(listed, "agent bridge lists the scoped client")
    try expect(
      engine.runtime.navigateTabID(
        tabID, profileID: target.profileID.uuidString, windowID: engine.windowID,
        url: fixture.appending(path: "agent-bridge-revoked").absoluteString),
      "navigate the granted tab")
    var revoked = false
    for _ in 0..<50 {
      let (statusData, statusError) = await agentRequest(
        operation: 1007, tabID: tabID, target: target)
      if statusError == nil, let statusData,
        let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
        status["enabled"] as? Bool == false
      {
        revoked = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(revoked, "agent bridge revokes the grant on navigation")
  }

  private func prepareAgentBridgePages(
    grantedTabID: String, target: SiteControlTarget
  ) async throws -> String {
    try expect(
      engine.runtime.navigateTabID(
        grantedTabID, profileID: target.profileID.uuidString, windowID: engine.windowID,
        url: fixture.appending(path: "agent-bridge").absoluteString),
      "navigate the granted tab to the agent-bridge fixture")
    try await wait("granted tab records its console message and network body") {
      let page = await self.pageObject(grantedTabID, "window.__shaarAgent")
      let console = page?["console"] as? [String]
      return page?["role"] as? String == "granted"
        && console?.contains("shaar-agent-console-granted") == true
        && page?["network"] as? String == "shaar-agent-network-granted"
    }
    let existing = Set(store.session.selectedSpace.tabs.map(\.id))
    store.perform(.open(fixture.appending(path: "agent-bridge-other")))
    try await wait("other tab opens beside the granted tab") {
      self.store.session.selectedSpace.tabs.contains { !existing.contains($0.id) }
    }
    guard
      let other = store.session.selectedSpace.tabs.map(\.id).first(where: { !existing.contains($0) })
    else { throw Failure("No second agent tab") }
    let otherID = other.uuidString
    try await wait("other tab records a different console and DOM marker") {
      guard self.engine.liveTabs.contains(other), self.engine.pages[other]?.loading == false
      else { return false }
      let page = await self.pageObject(otherID, "window.__shaarAgent")
      return page?["role"] as? String == "other"
    }
    return otherID
  }

  private func closeProbeTab(_ tabID: String) {
    guard let id = UUID(uuidString: tabID) else { return }
    store.closeTab(id)
  }

  private func pageObject(_ tabID: String, _ script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      engine.runtime.evaluate(inTabID: tabID, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func readGrantedTab(_ client: ScopedAgentClient, session: String) async throws {
    _ = try protocolResult(try await client.call("DOM.enable", session: session))
    let document = try protocolResult(
      try await client.call("DOM.getDocument", session: session, params: ["depth": 0]))
    guard let root = document["root"] as? [String: Any],
      let documentURL = root["documentURL"] as? String,
      documentURL.contains("/account/agent-bridge"), !documentURL.contains("agent-bridge-other"),
      let rootID = root["nodeId"] as? Int
    else { throw Failure("Agent bridge DOM was not the granted tab") }
    checks.append("agent bridge reads the granted tab document")
    let query = try protocolResult(
      try await client.call(
        "DOM.querySelector", session: session,
        params: ["nodeId": rootID, "selector": "#shaar-agent-dom"]))
    guard let nodeID = query["nodeId"] as? Int, nodeID > 0 else {
      throw Failure("Agent bridge could not find the granted tab marker")
    }
    let outer = try protocolResult(
      try await client.call("DOM.getOuterHTML", session: session, params: ["nodeId": nodeID]))
    guard let html = outer["outerHTML"] as? String, html.contains("data-role=\"granted\""),
      !html.contains("data-role=\"other\"")
    else { throw Failure("Agent bridge DOM HTML was not limited to the granted tab") }
    checks.append("agent bridge reads only the granted tab DOM")
    try expect(
      try await evaluatedString(client, session: session, expression: "window.__shaarAgent.console[0]")
        == "shaar-agent-console-granted",
      "agent bridge reads the granted tab console record")
    try expect(
      try await evaluatedString(
        client, session: session, expression: "window.__shaarAgent.network")
        == "shaar-agent-network-granted",
      "agent bridge reads the granted tab network body")
    _ = try protocolResult(try await client.call("Network.enable", session: session))
    _ = try protocolResult(try await client.call("Log.enable", session: session))
    checks.append("agent bridge enables Network and Log on the granted tab")
  }

  private func refuseUngrantedReads(_ client: ScopedAgentClient) async throws {
    for method in ["DOM.getDocument", "Runtime.evaluate", "Network.enable"] {
      let params = readParameters(for: method)
      let browser = try await client.call(method, params: params)
      guard browser["error"] != nil else {
        throw Failure("Agent bridge allowed \(method) outside the granted session")
      }
      let foreign = try await client.call(
        method, session: "not-the-granted-session", params: params)
      guard foreign["error"] != nil else {
        throw Failure("Agent bridge allowed \(method) on a foreign session")
      }
    }
    checks.append(
      "agent bridge refuses Console, Network, and DOM reads outside the granted tab")
  }

  private func readParameters(for method: String) -> [String: Any]? {
    guard method == "Runtime.evaluate" else { return nil }
    return ["expression": "window.__shaarAgent.role", "returnByValue": true]
  }

  private func evaluatedString(
    _ client: ScopedAgentClient, session: String, expression: String
  ) async throws -> String {
    let result = try protocolResult(
      try await client.call(
        "Runtime.evaluate", session: session,
        params: ["expression": expression, "returnByValue": true]))
    guard let remote = result["result"] as? [String: Any],
      let value = remote["value"] as? String
    else { throw Failure("Agent bridge evaluation did not return a string") }
    return value
  }

  private func protocolResult(_ reply: [String: Any]) throws -> [String: Any] {
    guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else {
      let detail = String(describing: reply).prefix(500)
      throw Failure("Agent bridge command failed: \(detail)")
    }
    return result
  }

  private func expectOtherTabDisabled(_ tabID: String, target: SiteControlTarget) async throws {
    let (data, error) = await agentRequest(operation: 1007, tabID: tabID, target: target)
    guard error == nil, let data,
      let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      status["enabled"] as? Bool == false, status["token"] == nil
    else { throw Failure("Agent bridge exposed a grant for the other tab") }
    checks.append("agent bridge status on the other tab stays disabled")
  }

  private func connectionCount(tabID: String, target: SiteControlTarget) async -> Int {
    let (data, error) = await agentRequest(operation: 1007, tabID: tabID, target: target)
    guard error == nil, let data,
      let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let count = status["connectionCount"] as? Int
    else { return -1 }
    return count
  }

  @MainActor
  private final class ScopedAgentClient {
    let task: URLSessionWebSocketTask
    private var nextID: Int

    init(task: URLSessionWebSocketTask, nextID: Int) {
      self.task = task
      self.nextID = nextID
    }

    func call(
      _ method: String, session: String? = nil, params: [String: Any]? = nil
    ) async throws -> [String: Any] {
      let id = nextID
      nextID += 1
      var object: [String: Any] = ["id": id, "method": method]
      if let session { object["sessionId"] = session }
      if let params { object["params"] = params }
      let data = try JSONSerialization.data(withJSONObject: object)
      guard let text = String(data: data, encoding: .utf8) else {
        throw Failure("Could not encode \(method)")
      }
      try await task.send(.string(text))
      for _ in 0..<6 {
        guard let reply = try await receiveObject() else { continue }
        if reply["id"] as? Int == id { return reply }
      }
      throw Failure("Agent bridge did not answer \(method)")
    }

    private func receiveObject() async throws -> [String: Any]? {
      let message = try await task.receive()
      let payload = websocketText(message)
      guard let payload, let body = payload.data(using: .utf8) else { return nil }
      return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func websocketText(_ message: URLSessionWebSocketTask.Message) -> String? {
      switch message {
      case .string(let value): return value
      case .data(let value): return String(data: value, encoding: .utf8)
      @unknown default: return nil
      }
    }
  }

  private func wait(_ message: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<Int(150 * ProbeTimeout.scale) {
      if await condition() {
        checks.append(message)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure(
      "Timed out: \(message); dock=\(dockAudit(store.session.selectedPage?.tab.id.uuidString ?? ""))"
    )
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    let value: [String: Any] = [
      "phase": phase, "passed": error == nil, "checks": checks,
      "requests": requests,
      "error": error?.localizedDescription as Any? ?? NSNull(),
      "scope":
        "Hidden app-owned tabs for MCP and Node DevTools; no visible window or physical input.",
    ]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-devtools-route.json"), options: .atomic)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
