// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite(.serialized) @MainActor struct ShaarDevToolsPublicRouteTests {
  @Test func publicShortcutsOpenTheChromiumDock() throws {
    let legacy = LegacyShellDefault(enabled: false)
    defer { legacy.restore() }
    let fixture = try PublicRouteFixture()
    defer { fixture.cleanUp() }
    let context = try fixture.context()
    let tab = try fixture.tabID()

    #expect(hostCanOpenDevTools(fixture.host))
    #expect(fixture.host.performDeveloperToolsKey(try fixture.f12Event()))
    #expect(fixture.runtime.toggledTabs == [tab.uuidString])
    #expect(context.engine.shaarDevTools[tab]?.isOpen != true)

    NSApp.mainMenu = fixture.host.menu
    NSApp.sendEvent(try fixture.f12Event())
    #expect(fixture.runtime.toggledTabs == [tab.uuidString, tab.uuidString])

    NSApp.sendEvent(try fixture.optionCommandIEvent())
    #expect(fixture.runtime.toggledTabs.count == 3)
    #expect(context.engine.shaarDevTools[tab]?.isOpen != true)
  }

  @Test func legacyDefaultMakesThePublicShortcutsOpenTheShell() throws {
    let legacy = LegacyShellDefault(enabled: true)
    defer { legacy.restore() }
    let fixture = try PublicRouteFixture()
    defer { fixture.cleanUp() }
    let context = try fixture.context()
    let tab = try fixture.tabID()

    #expect(fixture.host.performDeveloperToolsKey(try fixture.f12Event()))
    #expect(fixture.runtime.toggledTabs.isEmpty)
    #expect(context.engine.shaarDevTools[tab]?.isOpen == true)

    context.engine.toggleDeveloperTools()
    #expect(context.engine.shaarDevTools[tab]?.isOpen != true)
    NSApp.mainMenu = fixture.host.menu
    NSApp.sendEvent(try fixture.optionCommandIEvent())
    #expect(fixture.runtime.toggledTabs.isEmpty)
    #expect(context.engine.shaarDevTools[tab]?.isOpen == true)
  }

  @Test func optionShiftCommandIStillOpensTheChromiumDock() throws {
    let legacy = LegacyShellDefault(enabled: true)
    defer { legacy.restore() }
    let fixture = try PublicRouteFixture()
    defer { fixture.cleanUp() }
    let context = try fixture.context()
    let tab = try fixture.tabID()

    NSApp.mainMenu = fixture.host.menu
    NSApp.sendEvent(try fixture.optionShiftCommandIEvent())
    #expect(fixture.runtime.toggledTabs == [tab.uuidString])
    #expect(context.engine.shaarDevTools[tab]?.isOpen != true)
  }

  @Test func privateWindowFollowsTheSamePublicRoute() throws {
    let legacy = LegacyShellDefault(enabled: false)
    defer { legacy.restore() }
    let fixture = try PublicRouteFixture()
    defer { fixture.cleanUp() }
    let owner = try fixture.openPrivateWindow()
    let tab = try #require(owner.store.session.selectedPage?.tab.id)

    #expect(!owner.window.isVisible)
    #expect(fixture.host.canPerform(.developerTools))
    #expect(fixture.host.performDeveloperToolsKey(try fixture.f12Event(in: owner.window)))
    #expect(fixture.runtime.privateToggles == [tab.uuidString])
    #expect(fixture.runtime.toggledTabs.isEmpty)
    #expect(owner.page.shaarDevTools[tab]?.isOpen != true)

    NSApp.mainMenu = fixture.host.menu
    NSApp.sendEvent(try fixture.optionCommandIEvent(in: owner.window))
    #expect(fixture.runtime.privateToggles == [tab.uuidString, tab.uuidString])
    #expect(owner.page.shaarDevTools[tab]?.isOpen != true)

    let shell = LegacyShellDefault(enabled: true)
    defer { shell.restore() }
    #expect(fixture.host.performDeveloperToolsKey(try fixture.f12Event(in: owner.window)))
    #expect(fixture.runtime.privateToggles.count == 2)
    #expect(owner.page.shaarDevTools[tab]?.isOpen == true)
  }

  @Test func siteControlShowStaysOnTheSelectedTarget() throws {
    let legacy = LegacyShellDefault(enabled: false)
    defer { legacy.restore() }
    let fixture = try PublicRouteFixture()
    defer { fixture.cleanUp() }
    let context = try fixture.context()
    let tab = try fixture.tabID()
    let current = try #require(context.engine.siteControlTarget)
    let stale = SiteControlTarget(tabID: tab, profileID: current.profileID, url: URL(string: "https://stale.example/")!)

    #expect(!context.engine.showDeveloperTools(for: stale))
    #expect(context.engine.shaarDevTools[tab]?.isOpen != true)
    #expect(context.engine.showDeveloperTools(for: current))
    #expect(context.engine.shaarDevTools[tab]?.isOpen == true)
    #expect(fixture.runtime.toggledTabs.isEmpty)
    context.engine.togglePublicDeveloperTools()
    #expect(fixture.runtime.toggledTabs == [tab.uuidString])
  }
}

@MainActor private func hostCanOpenDevTools(_ host: NativeBrowserHost) -> Bool {
  host.canPerform(.developerTools) && host.canPerform(.chromiumDeveloperTools)
}

@MainActor private final class LegacyShellDefault {
  private let key = ShaarDevToolsRoute.legacyShellDefaultsKey
  private let previous: Any?

  init(enabled: Bool) {
    previous = UserDefaults.standard.object(forKey: key)
    if enabled {
      UserDefaults.standard.set(true, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  func restore() {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

@MainActor private final class PublicRouteKey {
  var window: NSWindow?
}

@MainActor private final class PublicRouteFixture {
  let root = FileManager.default.temporaryDirectory.appending(path: "devtools-route-\(UUID().uuidString)")
  let runtime = PublicRouteRuntime()
  let host: NativeBrowserHost
  let key = PublicRouteKey()

  init() throws {
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://localhost:3000")!)
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file, initialSession: session)
    let key = self.key
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe, usesPrimaryWindow: false,
      keyWindow: { key.window },
      screens: { [NSRect(x: -20000, y: -20000, width: 1280, height: 800)] })
    try host.restore()
    let context = try self.context()
    key.window = context.window
    context.window.orderOut(nil)
    let tab = try tabID()
    context.engine.liveTabs.insert(tab)
    runtime.tabWindows[tab.uuidString] = context.nativeID
  }

  func context() throws -> NativeBrowserContext {
    try #require(host.contexts.values.first)
  }

  func tabID() throws -> UUID {
    try #require(context().store.session.selectedPage?.tab.id)
  }

  func openPrivateWindow() throws -> PrivateBrowserHost.Owner {
    host.perform(.newPrivateWindow)
    let owner = try #require(host.privateWindowOwners.first)
    owner.window.orderOut(nil)
    key.window = owner.window
    return owner
  }

  func f12Event(in window: NSWindow? = nil) throws -> NSEvent {
    try keyEvent(keyCode: 111, characters: "\u{F70F}", modifiers: [], in: window)
  }

  func optionCommandIEvent(in window: NSWindow? = nil) throws -> NSEvent {
    try keyEvent(keyCode: 34, characters: "i", modifiers: [.command, .option], in: window)
  }

  func optionShiftCommandIEvent(in window: NSWindow? = nil) throws -> NSEvent {
    try keyEvent(
      keyCode: 34, characters: "i", modifiers: [.command, .option, .shift], in: window)
  }

  func cleanUp() {
    host.detach()
    for window in runtime.windows.values { window.orderOut(nil); window.close() }
    for window in runtime.privateWindows.values { window.orderOut(nil); window.close() }
    try? FileManager.default.removeItem(at: root)
  }

  private func keyEvent(
    keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow?
  ) throws -> NSEvent {
    let target = try #require(window ?? key.window)
    return try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode))
  }
}

private final class PublicRouteRuntime: ARCShaarRuntime, @unchecked Sendable {
  var windows: [String: NSWindow] = [:]
  var tabWindows: [String: String] = [:]
  var toggledTabs: [String] = []
  var privateToggles: [String] = []
  var privateWindows: [String: NSWindow] = [:]
  var privateViews: [String: NSView] = [:]

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {}

  override func createWindowID(_ windowID: String) throws {
    MainActor.assumeIsolated {
      windows[windowID] = Self.makeHiddenWindow()
    }
  }

  override func isWindowOpenID(_ windowID: String) -> Bool { windows[windowID] != nil }
  override func window(forID windowID: String) -> NSWindow? { windows[windowID] }
  override func hostView(forWindowID windowID: String) -> NSView? {
    MainActor.assumeIsolated { windows[windowID]?.contentView }
  }
  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }

  @MainActor override func toggleDevTools(
    forTabID tabID: String, completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    toggledTabs.append(tabID)
    completion(nil)
  }

  @MainActor override func panelRequest(
    _ operation: UInt, tabID: String, profileID: String, windowID: String,
    payload: [String: Any],
    completion: @escaping @MainActor @Sendable ([String: Any]?, Error?) -> Void
  ) {
    completion(nil, CocoaError(.featureUnsupported))
  }

  override func createPrivateContextID(
    _ contextID: String, sourceProfileID: String,
    completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
  ) {
    MainActor.assumeIsolated { completion(true, nil) }
  }

  override func createPrivateWindowID(
    _ windowID: String, contextID: String, tabID: String, url: String
  ) throws {
    MainActor.assumeIsolated {
      let window = Self.makeHiddenWindow()
      privateWindows[windowID] = window
      privateViews[tabID] = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    }
  }

  override func window(forPrivateWindowID windowID: String, contextID: String) -> NSWindow? {
    privateWindows[windowID]
  }

  override func hostView(forPrivateWindowID windowID: String, contextID: String) -> NSView? {
    MainActor.assumeIsolated { privateWindows[windowID]?.contentView }
  }

  override func view(
    forPrivateTabID tabID: String, windowID: String, contextID: String
  ) -> NSView? {
    privateViews[tabID]
  }

  @MainActor override func toggleDevTools(
    forPrivateTabID tabID: String, windowID: String, contextID: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    privateToggles.append(tabID)
    completion(nil)
  }

  @MainActor private static func makeHiddenWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderOut(nil)
    return window
  }
}
