// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Test @MainActor func newMiniWindowRequiresANormalWindowTarget() throws {
  let workspace = try BrowserWorkspaceStore()
  try workspace.removeWindow(workspace.workspace.windows[0].id)
  let host = NativeBrowserHost(
    events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
    presentation: .hiddenProbe, usesPrimaryWindow: false, keyWindow: { nil })

  #expect(workspace.workspace.windows.isEmpty)
  #expect(!host.canPerform(.newMiniWindow))
}

@Test @MainActor func newPrivateWindowStaysAvailableAfterLastNormalWindowCloses() throws {
  let workspace = try BrowserWorkspaceStore()
  try workspace.removeWindow(workspace.workspace.windows[0].id)
  let host = NativeBrowserHost(
    events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
    presentation: .hiddenProbe, usesPrimaryWindow: false, keyWindow: { nil })

  #expect(workspace.workspace.windows.isEmpty)
  #expect(host.canPerform(.newPrivateWindow))
  #expect(
    host.privateWindowSourceProfileID()
      == workspace.workspace.catalog.spaces[0].profileID.uuidString)
}

@Test @MainActor func newWindowCommandRoutesThroughTheHostAndRollsBackFailedAttachment() throws {
  let workspace = try BrowserWorkspaceStore()
  let originalWindowIDs = workspace.workspace.windows.map(\.id)
  let host = NativeBrowserHost(
    events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
    presentation: .hiddenProbe, usesPrimaryWindow: false)
  defer { host.detach() }

  #expect(throws: (any Error).self) { try host.restore() }
  #expect(host.canPerform(.newWindow))
  host.perform(.newWindow)

  #expect(host.lastError != nil)
  #expect(workspace.workspace.windows.map(\.id) == originalWindowIDs)
}

@Test @MainActor func nextAndPreviousWindowCommandsCycleWithoutPresentingWindows() {
  let first = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  let second = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  let third = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  var activated: NSWindow?

  let next = NativeBrowserHost.cycledWindow(
    from: first, among: [first, second, third], backwards: false, activate: { activated = $0 })
  let previous = NativeBrowserHost.cycledWindow(
    from: first, among: [first, second, third], backwards: true)
  #expect(next === second && activated === second)
  #expect(previous === third)
  #expect(!first.isVisible && !second.isVisible && !third.isVisible)
}

@Test @MainActor func nativeMenusMatchArcGroupsAndRouteEveryImplementedCommandOnce() {
  let application = NSApplication.shared
  let menu = NativeBrowserHost.makeMenu(target: application)
  let groups = menu.items.compactMap(\.submenu)
  #expect(
    groups.map(\.title) == [
      "Shaar", "File", "Edit", "View", "Spaces", "Tabs", "History", "Bookmarks",
      "Extensions", "Window", "Help",
    ])

  let commandItems = groups.flatMap(\.items).compactMap { item -> (String, NSMenuItem)? in
    guard let command = item.representedObject as? String else { return nil }
    return (command, item)
  }
  let menuCommands = Set(
    BrowserMenuCommand.allCases.map(\.rawValue).filter {
      $0 != BrowserMenuCommand.chromiumDeveloperTools.rawValue
    })
  #expect(Set(commandItems.map(\.0)) == menuCommands)
  #expect(commandItems.count == menuCommands.count)

  func item(_ command: BrowserMenuCommand) -> NSMenuItem? {
    commandItems.first { $0.0 == command.rawValue }?.1
  }
  #expect(item(.newPrivateWindow)?.menu?.title == "File")
  #expect(item(.newWindow)?.menu?.title == "File")
  #expect(item(.newWindow)?.title == "New window")
  #expect(item(.newWindow)?.keyEquivalent == "n")
  #expect(item(.newWindow)?.keyEquivalentModifierMask == .command)
  #expect(item(.closeWindow)?.menu?.title == "File")
  #expect(item(.sharePage)?.menu?.title == "File")
  #expect(item(.find)?.menu?.title == "Edit")
  #expect(item(.reload)?.menu?.title == "View")
  #expect(item(.hardReload)?.menu?.title == "View")
  #expect(item(.hardReload)?.keyEquivalent == "r")
  #expect(item(.hardReload)?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item(.developerTools)?.menu?.title == "View")
  #expect(item(.developerTools)?.title == "Developer Tools")
  #expect(item(.developerTools)?.keyEquivalent == "i")
  #expect(item(.developerTools)?.keyEquivalentModifierMask == [.command, .option])
  #expect(item(.chromiumDeveloperTools) == nil)
  #expect(!commandItems.contains { $0.1.title == "Shaar DevTools" })
  #expect(!commandItems.contains { $0.1.title == "Open Chromium DevTools" })
  #expect(item(.newSpace)?.menu?.title == "Spaces")
  #expect(item(.closeTab)?.menu?.title == "Tabs")
  #expect(item(.bookmarks)?.menu?.title == "Bookmarks")
  #expect(item(.bookmarkPage)?.menu?.title == "Bookmarks")
  #expect(item(.history)?.menu?.title == "History")
  #expect(item(.history)?.title == "Show All History")
  #expect(item(.history)?.representedObject as? String == BrowserMenuCommand.history.rawValue)
  #expect(item(.recentlyClosed)?.menu?.title == "History")
  #expect(item(.downloads)?.menu?.title == "File")
  #expect(item(.extensions)?.menu?.title == "Extensions")
  #expect(item(.minimizeWindow)?.menu?.title == "Window")
  #expect(item(.nextWindow)?.menu?.title == "Window")
  #expect(item(.nextWindow)?.keyEquivalent == "`")
  #expect(item(.nextWindow)?.keyEquivalentModifierMask == .command)
  #expect(item(.previousWindow)?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item(.help)?.menu?.title == "Help")
  #expect(item(.checkForUpdates)?.menu?.title == "Shaar")
  #expect(item(.checkForUpdates)?.title == "Check for Updates…")
}

@Test @MainActor func sharePageMenuUsesOnlyASelectedWebPage() {
  let store = BrowserStore()
  #expect(NativeBrowserHost.shareURL(for: store) == nil)

  let url = URL(string: "https://share.example/page")!
  store.perform(.open(url))
  #expect(NativeBrowserHost.shareURL(for: store) == url)
}

@Test @MainActor func nativeMenuRetainsKeyEquivalentsAndEditResponderChain() {
  let application = NSApplication.shared
  let menu = NativeBrowserHost.makeMenu(target: application)
  let items = menu.items.compactMap(\.submenu).flatMap(\.items)
  func item(_ title: String) -> NSMenuItem? { items.first { $0.title == title } }

  #expect(item("New window")?.keyEquivalent == "n")
  #expect(item("New window")?.keyEquivalentModifierMask == .command)
  #expect(item("New Private Window")?.keyEquivalent == "n")
  #expect(item("New Private Window")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("New tab")?.keyEquivalent == "t")
  #expect(item(CommandPanel.searchPrompt)?.keyEquivalent == "l")
  #expect(item("Close tab")?.keyEquivalentModifierMask == .command)
  #expect(item("Close window")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("Find in Page…")?.keyEquivalent == "f")
  #expect(item("Next space")?.keyEquivalentModifierMask == [.command, .option])
  #expect(item("New Mini Window")?.keyEquivalent == "n")
  #expect(item("New Mini Window")?.keyEquivalentModifierMask == [.command, .option])
  #expect(item("New space…")?.keyEquivalent == "S")
  #expect(item("New Folder")?.keyEquivalentModifierMask == [.command, .control])
  #expect(item("Copy URL")?.keyEquivalentModifierMask == [.command, .option, .shift])
  #expect(item("Open source")?.keyEquivalent == "o")
  #expect(item("Open source")?.keyEquivalentModifierMask == [.command, .option])
  #expect(item("Copy for agent")?.keyEquivalent == "a")
  #expect(item("Copy for agent")?.keyEquivalentModifierMask == [.command, .option, .shift])
  #expect(item("Downloads")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("Undo")?.action == NSSelectorFromString("undo:"))
  #expect(item("Cut")?.action == NSSelectorFromString("cut:"))
  #expect(item("Copy")?.action == NSSelectorFromString("copy:"))
  #expect(item("Paste")?.action == NSSelectorFromString("paste:"))
  #expect(item("Paste and Match Style")?.action == NSSelectorFromString("pasteAsPlainText:"))
  #expect(item("Paste and Match Style")?.keyEquivalent == "V")
  #expect(item("Paste and Match Style")?.keyEquivalentModifierMask == [.command, .option])
  #expect(item("Select All")?.action == NSSelectorFromString("selectAll:"))
  #expect(item("Undo")?.target == nil && item("Paste")?.target == nil)
  #expect(item("Paste and Match Style")?.target == nil)
}

@Test @MainActor func copyURLMenuUsesTheActivePrivatePage() throws {
  let session = try BrowserSession.privateWindow(
    sourceProfileID: UUID(), firstTabID: UUID())
  let privateStore = BrowserStore(privateSession: session)
  privateStore.perform(.open(URL(string: "https://private.example/page")!))

  #expect(NativeBrowserHost.copyURLMenuAvailable(in: privateStore, menusEnabled: true))
  #expect(!NativeBrowserHost.copyURLMenuAvailable(in: BrowserStore(), menusEnabled: true))
  #expect(!NativeBrowserHost.copyURLMenuAvailable(in: privateStore, menusEnabled: false))
}
