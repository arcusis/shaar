// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WorkspaceQuitPersistenceTests {
  @Test(arguments: [false, true])
  func quitRetainsWindowsAndOrdinaryTabsOnDisk(nativeInitiated: Bool) throws {
    let fixture = try QuitWorkspaceFixture(additionalWindow: true)
    defer { fixture.cleanUp() }
    let before = fixture.workspace.workspace
    if nativeInitiated {
      fixture.runtime.quit()
    } else {
      fixture.host.perform(.quit)
    }
    try fixture.workspace.flushSaves()
    let loaded = try fixture.file.load()
    let saved = try #require(loaded)
    #expect(fixture.host.contexts.isEmpty)
    #expect(saved.windows.map(\.id) == before.windows.map(\.id))
    #expect(saved.windows.map(\.session) == before.windows.map(\.session))
  }

  @Test func cancelledQuitAllowsLaterUserTabAndWindowCloses() throws {
    let fixture = try QuitWorkspaceFixture()
    defer { fixture.cleanUp() }
    fixture.runtime.cancelQuit = true
    fixture.host.perform(.quit)
    let context = try #require(fixture.host.contexts.values.first)
    let tab = try #require(context.store.session.selectedPage?.tab.id)
    fixture.runtime.onTabClosed?(tab.uuidString)
    #expect(context.store.session.page(forTabID: tab) == nil)
    #expect(context.store.session.closedTabs.contains { $0.tab.id == tab })
    fixture.runtime.onWindowClosed?(context.nativeID, false)
    try fixture.workspace.flushSaves()
    let loaded = try fixture.file.load()
    #expect(loaded?.windows.isEmpty == true)
  }

  @Test func appKitCloseRetiresWindowBeforeSavedTabCanReload() throws {
    let fixture = try QuitWorkspaceFixture(additionalWindow: true)
    defer { fixture.cleanUp() }
    let context = try #require(fixture.host.contexts.values.first)
    let tab = try #require(context.store.session.selectedPage?.tab.id)

    context.window.close()
    context.engine.reconcile()

    #expect(context.engine.isClosed)
    #expect(fixture.host.contexts[context.id] == nil)
    #expect(!context.store.reloadCurrentPage())
    #expect(!fixture.host.events.router.bindTab(tab.uuidString, windowID: context.nativeID))
  }
}

@MainActor
private final class QuitWorkspaceFixture {
  let root = FileManager.default.temporaryDirectory.appending(path: "quit-\(UUID())")
  let file: WorkspaceFile
  let workspace: BrowserWorkspaceStore
  let runtime = WorkspaceQuitRuntime()
  let host: NativeBrowserHost

  init(additionalWindow: Bool = false) throws {
    file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    var session = BrowserSession.fresh()
    let opened = session.open(URL(string: "https://example.com/pin")!)
    let pin = try #require(opened)
    session.togglePin(pin)
    _ = session.open(URL(string: "https://example.com/ordinary")!)
    workspace = try BrowserWorkspaceStore(file: file, initialSession: session)
    if additionalWindow {
      let window = try workspace.newWindow(from: workspace.workspace.focusedWindowID)
      workspace.stores[window]?.perform(.open(URL(string: "https://example.com/second-window")!))
    }
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe, usesPrimaryWindow: false)
    try host.restore()
    for context in host.contexts.values {
      for tab in context.store.session.spaces.flatMap(\.tabs) {
        context.engine.liveTabs.insert(tab.id)
        runtime.tabWindows[tab.id.uuidString] = context.nativeID
        #expect(host.events.router.bindTab(tab.id.uuidString, windowID: context.nativeID))
      }
    }
    #expect(workspace.persistSnapshot())
  }

  func cleanUp() {
    host.detach()
    for window in runtime.windows.values { window.close() }
    try? FileManager.default.removeItem(at: root)
  }
}

private final class WorkspaceQuitRuntime: ARCShaarRuntime, @unchecked Sendable {
  var windows: [String: NSWindow] = [:]
  var tabWindows: [String: String] = [:]
  var cancelQuit = false
  nonisolated(unsafe) var quittingForTest = false
  override var isQuitting: Bool { quittingForTest }
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
  override func quit() {
    MainActor.assumeIsolated {
      quittingForTest = true
      onQuitRequested?()
      if cancelQuit {
        quittingForTest = false
        onQuitCancelled?()
        return
      }
      for tab in tabWindows.keys {
        onTabChanged?(tab, "about:blank", "", false, false, false)
        onTabClosed?(tab)
      }
      // Quit intent belongs to the app even when an individual native close
      // arrives without the engine's quitting flag.
      for window in windows.keys { onWindowClosed?(window, false) }
    }
  }
}
