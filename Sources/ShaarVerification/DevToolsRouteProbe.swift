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
    guard let target = engine.siteControlTarget else { throw Failure("No selected target") }
    try expect(engine.showDeveloperTools(for: target), "open selected tab DevTools")
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
    try await wait("closing MCP tab leaves DevTools alive") {
      engine.liveTabs.contains(tab) && dockAudit(identity)?["open"] as? Bool == true
    }
    try expect(
      await route(tab: identity, operation: 1091, payload: ["schemaVersion": 1]),
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
    store.perform(.space(returningTo))
    try expect(store.removeSpace(space), "close the isolated DevTools Space")
  }

  private func dockAudit(_ tabID: String) -> [AnyHashable: Any]? {
    ARCProbeDevToolsDockAudit(engine.runtime, tabID, engine.windowID, nil)
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

  private func wait(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<Int(150 * ProbeTimeout.scale) {
      if condition() {
        checks.append(message)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure(
      "Timed out: \(message); dock=\(String(describing: dockAudit(store.session.selectedPage?.tab.id.uuidString ?? "")))"
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
