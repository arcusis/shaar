// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DevToolsRequestedTabTests {
  @Test func nodeFrontendURLIsLimitedToBundledDevToolsPages() {
    var session = BrowserSession.fresh()
    let node = URL(string: "devtools://devtools/bundled/js_app.html?ws=localhost:9229/node")!
    let discovery = URL(string: "devtools://devtools/bundled/node_app.html?remoteBase=/serve_rev")!
    let profile = session.selectedSpace.profileID
    #expect(session.open(node) == nil)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: node), profileID: profile, openerID: nil,
        foreground: true) != nil)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: discovery), profileID: profile, openerID: nil,
        foreground: true) != nil)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: URL(string: "devtools://evil/bundled/js_app.html")!),
        profileID: profile, openerID: nil, foreground: true) == nil)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: URL(string: "devtools://devtools/bundled/other.html")!),
        profileID: profile, openerID: nil, foreground: true) == nil)
  }

  @Test func requestedNodeFrontendOpensOnlyInItsOwnedHiddenWindow() throws {
    let fixture = try DevToolsWindowFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.host.contexts.values.first)
    let source = try #require(owner.store.session.selectedPage?.tab.id)
    fixture.runtime.tabWindows[source.uuidString] = owner.nativeID
    owner.engine.liveTabs.insert(source)
    let before = owner.store.session.selectedSpace.tabs.count
    let request: [String: Any] = [
      "schemaVersion": 1, "kind": "openURLRequested", "sourceWindowID": owner.nativeID,
      "sourceTabID": source.uuidString,
      "profileID": owner.store.session.selectedSpace.profileID.uuidString,
      "url": "devtools://devtools/bundled/js_app.html?ws=localhost:9229/node",
      "disposition": "newForegroundTab",
    ]

    fixture.runtime.onDevToolsOpenURLRequest?(request)

    #expect(owner.store.session.selectedSpace.tabs.count == before + 1)
    #expect(owner.store.session.selectedPage?.tab.url.scheme == "devtools")
    #expect(fixture.host.contexts.count == 1)
    #expect(!owner.window.isVisible)

    var forged = request
    forged["sourceWindowID"] = UUID().uuidString
    fixture.runtime.onDevToolsOpenURLRequest?(forged)
    #expect(owner.store.session.selectedSpace.tabs.count == before + 1)
    #expect(
      ARCProbeShaarDevToolsURLDispatch(request, true)["url"] as? String == request["url"] as? String
    )
    #expect(ARCProbeShaarDevToolsURLDispatch(request, false).isEmpty)
  }

  @Test func failedPageReloadRehomesRetiredEngineWindow() throws {
    let fixture = try DevToolsWindowFixture()
    defer { fixture.cleanUp() }
    let original = try #require(fixture.host.contexts.values.first)
    let tab = try #require(original.store.session.selectedPage?.tab.id)
    let profile = original.store.session.selectedSpace.profileID
    original.store.nativeRendererGone(tab, profileID: profile, status: "renderer_gone", exitCode: 0)
    let failure = try #require(original.store.rendererFailures[tab])
    fixture.runtime.closedWindows.insert(original.nativeID)

    #expect(!original.store.reloadFailedPage(failure.id))
    let replacement = try #require(fixture.host.contexts[original.id])
    #expect(replacement.nativeID != original.nativeID)
    #expect(replacement.store === original.store)
    #expect(replacement.store.session.selectedPage?.tab.id == tab)
    #expect(fixture.host.workspace.workspace.window(original.id) != nil)
    #expect(fixture.host.contexts.count == 1)
    #expect(!replacement.window.isVisible)
  }

  @Test func closedEventRehomesFailedPageBeforeReload() throws {
    let fixture = try DevToolsWindowFixture()
    defer { fixture.cleanUp() }
    let original = try #require(fixture.host.contexts.values.first)
    let tab = try #require(original.store.session.selectedPage?.tab.id)
    let profile = original.store.session.selectedSpace.profileID
    original.store.nativeRendererGone(tab, profileID: profile, status: "renderer_gone", exitCode: 0)

    fixture.runtime.onWindowClosed?(original.nativeID, false)

    let replacement = try #require(fixture.host.contexts[original.id])
    #expect(replacement.nativeID != original.nativeID)
    #expect(replacement.store === original.store)
    #expect(replacement.store.session.selectedPage?.tab.id == tab)
    #expect(fixture.host.workspace.workspace.window(original.id) != nil)
    #expect(fixture.host.contexts.count == 1)
    #expect(!replacement.window.isVisible)
  }

  @Test func userClosedFailedPageWindowStaysClosed() throws {
    let fixture = try DevToolsWindowFixture()
    defer { fixture.cleanUp() }
    let original = try #require(fixture.host.contexts.values.first)
    let tab = try #require(original.store.session.selectedPage?.tab.id)
    let profile = original.store.session.selectedSpace.profileID
    original.store.nativeRendererGone(tab, profileID: profile, status: "renderer_gone", exitCode: 0)

    original.window.close()

    #expect(fixture.host.contexts[original.id] == nil)
    #expect(fixture.host.workspace.workspace.window(original.id) == nil)
  }
}

@MainActor
private final class DevToolsWindowFixture {
  let root = FileManager.default.temporaryDirectory.appending(path: "devtools-\(UUID())")
  let runtime = DevToolsWindowRuntime()
  let host: NativeBrowserHost

  init() throws {
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://localhost:3000")!)
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file, initialSession: session)
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe, usesPrimaryWindow: false)
    try host.restore()
  }

  func cleanUp() {
    host.detach()
    for window in runtime.windows.values { window.close() }
    try? FileManager.default.removeItem(at: root)
  }
}

private final class DevToolsWindowRuntime: ARCShaarRuntime, @unchecked Sendable {
  var windows: [String: NSWindow] = [:]
  var tabWindows: [String: String] = [:]
  var closedWindows: Set<String> = []

  override func isWindowOpenID(_ windowID: String) -> Bool {
    windows[windowID] != nil && !closedWindows.contains(windowID)
  }

  override func retireClosedWindowID(_ windowID: String) {
    closedWindows.insert(windowID)
    MainActor.assumeIsolated { onWindowClosed?(windowID, false) }
  }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {}
  override func createWindowID(_ windowID: String) throws {
    MainActor.assumeIsolated {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      windows[windowID] = window
    }
  }
  override func window(forID windowID: String) -> NSWindow? { windows[windowID] }
  override func hostView(forWindowID windowID: String) -> NSView? {
    MainActor.assumeIsolated { windows[windowID]?.contentView }
  }
  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }
}
