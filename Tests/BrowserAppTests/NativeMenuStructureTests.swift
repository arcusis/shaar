// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Test @MainActor func printStaysUnavailableInPrivateWindowsUntilItsNativeRouteIsSupported() {
  #expect(!PrivateBrowserHost.supportsPrivateCommand(.print))
}

@Test @MainActor func printCommandRequiresASelectedPageAndNativeSupport() {
  #expect(!NativeBrowserHost.printCommandIsAvailable(
    hasSelectedPage: false, commandIsOpen: false, hasNativePrint: true))
  #expect(NativeBrowserHost.printCommandIsAvailable(
    hasSelectedPage: true, commandIsOpen: false, hasNativePrint: true))
  #expect(!NativeBrowserHost.printCommandIsAvailable(
    hasSelectedPage: true, commandIsOpen: false, hasNativePrint: false))
  #expect(!NativeBrowserHost.printCommandIsAvailable(
    hasSelectedPage: true, commandIsOpen: true, hasNativePrint: true))
}

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

@Test @MainActor func bringAllToFrontRoutesAcrossAppWindowsWithoutPresentingThem() throws {
  let workspace = try BrowserWorkspaceStore()
  let host = NativeBrowserHost(
    events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
    presentation: .hiddenProbe, usesPrimaryWindow: false, keyWindow: { nil })
  let settings = NSWindow(
    contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  let mini = NSWindow(
    contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  var ordered: [NSWindow] = []
  var keyed: NSWindow?

  #expect(host.canPerform(.bringAllToFront))
  NativeBrowserHost.bringAllWindowsToFront(
    [settings, mini], keyWindow: settings, orderFront: { ordered.append($0) },
    makeKey: { keyed = $0 })

  #expect(ordered.count == 2 && ordered[0] === settings && ordered[1] === mini)
  #expect(keyed === settings)
  #expect(!settings.isVisible && !mini.isVisible)
}

@Test @MainActor func nativeMenuTitlesResolveToHebrewCatalogEntries() {
  let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let groups = menu.items.compactMap(\.submenu)
  let identifiers = groups.compactMap { group -> String? in
    guard group.identifier?.rawValue != ProductIdentity.name else { return nil }
    return group.identifier?.rawValue
  } + groups.flatMap(\.items).compactMap { item -> String? in
    guard let identifier = item.identifier?.rawValue else { return nil }
    if item.representedObject as? String == BrowserMenuCommand.search.rawValue { return nil }
    return identifier == "copyCurrentURL:" ? item.title : identifier
  }
  for identifier in identifiers {
    let key: String
    switch identifier {
    case "About \(ProductIdentity.name)": key = "About %@"
    case "Hide \(ProductIdentity.name)": key = "Hide %@"
    case "Quit \(ProductIdentity.name)": key = "Quit %@"
    case "\(ProductIdentity.name) Support": key = "%@ Support"
    default: key = identifier
    }
    #expect(
      BrowserLocalization.string(key, table: "Shell", language: .hebrew) != key,
      "Native menu title lacks Hebrew catalog copy: \(identifier)")
  }
  for key in ["About %@", "Hide %@", "Quit %@", "%@ Support"] {
    #expect(
      BrowserLocalization.format(
        key, table: "Shell", language: .hebrew,
        arguments: [.string(ProductIdentity.name)]) != key)
  }
  #expect(
      BrowserLocalization.string("Search or enter address", table: "Shell", language: .hebrew)
      != "Search or enter address")
}

@Test @MainActor func reopenClosedShortcutPrefersATabThenFallsBackToAWindow() {
  #expect(
    NativeBrowserHost.reopenClosedShortcutCommand(canReopenTab: true, hasClosedWindow: true)
      == .reopenClosed)
  #expect(
    NativeBrowserHost.reopenClosedShortcutCommand(canReopenTab: false, hasClosedWindow: true)
      == .reopenClosedWindow)
  #expect(
      NativeBrowserHost.reopenClosedShortcutCommand(canReopenTab: false, hasClosedWindow: false)
      == nil)
}

@Test @MainActor func reopenClosedWindowCommandRoutesAndPreservesSnapshotOnAttachFailure() throws {
  let runtime = ARCChromiumRuntime()
  let workspace = try BrowserWorkspaceStore()
  let host = NativeBrowserHost(
    events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
    presentation: .hiddenProbe, usesPrimaryWindow: false, keyWindow: { nil })
  defer { host.detach() }
  var snapshotSession = workspace.workspace.windows[0].session
  let spaceID = snapshotSession.selectedSpaceID
  for tab in snapshotSession.selectedSpace.tabs where !tab.isPinned { snapshotSession.closeTab(tab.id) }
  for closed in snapshotSession.recentlyClosedTabs(in: spaceID) {
    _ = snapshotSession.reopenClosedTab(closed.id, in: spaceID)
  }
  _ = snapshotSession.open(URL(string: "https://restored-window.example")!)
  let snapshot = try #require(BrowserWorkspace(session: snapshotSession).windows.first)
  host.lastClosedWindowSnapshot = snapshot
  let windowIDs = workspace.workspace.windows.map(\.id)
  #expect(throws: (any Error).self) { try host.restore() }
  #expect(host.canPerform(.reopenClosed))
  #expect(host.canPerform(.reopenClosedWindow))
  host.perform(.reopenClosedWindow)
  #expect(host.lastError != nil)
  #expect(host.lastClosedWindowSnapshot == snapshot)
  #expect(workspace.workspace.windows.map(\.id) == windowIDs)
}

@Test @MainActor func bringAllToFrontDoesNotMakeAWindowKeyWhenItIsNotVisible() {
  let staleKeyWindow = NSWindow(
    contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  let visibleWindow = NSWindow(
    contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  var ordered: [NSWindow] = []
  var keyed: NSWindow?

  NativeBrowserHost.bringAllWindowsToFront(
    [visibleWindow], keyWindow: staleKeyWindow, orderFront: { ordered.append($0) },
    makeKey: { keyed = $0 })

  #expect(ordered.count == 1 && ordered[0] === visibleWindow)
  #expect(keyed == nil)
  #expect(!staleKeyWindow.isVisible && !visibleWindow.isVisible)
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
  #expect(item(.openFile)?.menu?.title == "File")
  #expect(item(.openFile)?.title == "Open File…")
  #expect(item(.openFile)?.keyEquivalent == "o")
  #expect(item(.openFile)?.keyEquivalentModifierMask == .command)
  #expect(item(.closeWindow)?.menu?.title == "File")
  #expect(item(.sharePage)?.menu?.title == "File")
  #expect(item(.print)?.menu?.title == "File")
  #expect(item(.print)?.title == "Print…")
  #expect(item(.print)?.keyEquivalent == "p")
  #expect(item(.print)?.keyEquivalentModifierMask == .command)
  #expect(item(.find)?.menu?.title == "Edit")
  #expect(item(.pasteAndGo)?.menu?.title == "Edit")
  #expect(item(.pasteAndGo)?.title == "Paste and Go")
  #expect(item(.reload)?.menu?.title == "View")
  #expect(item(.fullScreen)?.menu?.title == "View")
  #expect(item(.fullScreen)?.title == "Enter Full Screen")
  #expect(item(.fullScreen)?.keyEquivalent == "f")
  #expect(item(.fullScreen)?.keyEquivalentModifierMask == [.command, .control])
  #expect(item(.hardReload)?.menu?.title == "View")
  #expect(item(.zoomIn)?.menu?.title == "View")
  #expect(item(.zoomIn)?.keyEquivalent == "=")
  #expect(item(.zoomIn)?.keyEquivalentModifierMask == .command)
  #expect(item(.zoomOut)?.keyEquivalent == "-")
  #expect(item(.zoomOut)?.keyEquivalentModifierMask == .command)
  #expect(item(.actualSize)?.keyEquivalent == "0")
  #expect(item(.actualSize)?.keyEquivalentModifierMask == .command)
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
  #expect(item(.closeTab)?.menu?.title == "File")
  #expect(item(.closeTab)?.title == "Close tab")
  #expect(item(.closeTab)?.keyEquivalent == "w")
  #expect(item(.closeTab)?.keyEquivalentModifierMask == .command)
  #expect(item(.bookmarks)?.menu?.title == "Bookmarks")
  #expect(item(.bookmarkPage)?.menu?.title == "Bookmarks")
  #expect(item(.history)?.menu?.title == "History")
  #expect(item(.history)?.title == "Show All History")
  #expect(item(.history)?.representedObject as? String == BrowserMenuCommand.history.rawValue)
  #expect(item(.back)?.menu?.title == "History")
  #expect(item(.back)?.keyEquivalent == "[")
  #expect(item(.back)?.keyEquivalentModifierMask == .command)
  #expect(item(.forward)?.menu?.title == "History")
  #expect(item(.forward)?.keyEquivalent == "]")
  #expect(item(.forward)?.keyEquivalentModifierMask == .command)
  #expect(item(.clearHistory)?.menu?.title == "History")
  #expect(item(.clearHistory)?.title == "Clear History…")
  #expect(item(.clearHistory)?.keyEquivalent == "\u{8}")
  #expect(item(.clearHistory)?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item(.recentlyClosed)?.menu?.title == "History")
  #expect(item(.reopenClosedWindow)?.menu?.title == "History")
  #expect(
    item(.reopenClosedWindow)?.representedObject as? String
      == BrowserMenuCommand.reopenClosedWindow.rawValue)
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

@Test func pageZoomMenuRoutesOnlyTheFocusedTabToTheFakeEngine() {
  let tabID = UUID()
  var received: [(String, UUID)] = []
  let fakeEngine: (String, UUID) -> Bool = { action, tab in
    received.append((action, tab))
    return true
  }

  #expect(PageZoomMenuRouter.route(.zoomIn, focusedTabID: tabID, perform: fakeEngine))
  #expect(PageZoomMenuRouter.route(.zoomOut, focusedTabID: tabID, perform: fakeEngine))
  #expect(PageZoomMenuRouter.route(.actualSize, focusedTabID: tabID, perform: fakeEngine))
  #expect(!PageZoomMenuRouter.route(.zoomIn, focusedTabID: nil, perform: fakeEngine))
  #expect(!PageZoomMenuRouter.route(.reload, focusedTabID: tabID, perform: fakeEngine))
  #expect(received.map(\.0) == ["in", "out", "reset"])
  #expect(received.map(\.1) == [tabID, tabID, tabID])
}

@Test @MainActor func sharePageMenuUsesOnlyASelectedWebPage() {
  let store = BrowserStore()
  #expect(NativeBrowserHost.shareURL(for: store) == nil)

  let url = URL(string: "https://share.example/page")!
  store.perform(.open(url))
  #expect(NativeBrowserHost.shareURL(for: store) == url)
}

@Test @MainActor func bookmarkPageMenuOpensTheCurrentPageBookmarkEditor() {
  let store = BrowserStore()
  store.perform(.open(URL(string: "https://bookmark.example/current")!))

  NativeBrowserHost.bookmarkCurrentPage(in: store)

  guard case .bookmarkEditor(let route)? = store.sheet,
    case .newBookmark(_, _, let address) = route.mode
  else {
    Issue.record("Bookmark this page should open the bookmark editor")
    return
  }
  #expect(address == "https://bookmark.example/current")
}

@Test @MainActor func bookmarksMenuOpensTheBookmarksLibrarySection() {
  let store = BrowserStore()
  NativeBrowserHost.showBookmarks(in: store)
  guard case .library(_, .bookmarks) = store.sheet else {
    Issue.record("Bookmarks menu should open the bookmarks library section")
    return
  }
}

@Test @MainActor func recentlyClosedHistoryCommandOpensTheActiveSpaceList() {
  let store = BrowserStore()
  let activeSpaceID = store.session.selectedSpaceID
  NativeBrowserHost.showRecentlyClosed(in: store)
  guard case .recentlyClosed(let spaceID) = store.sheet else {
    Issue.record("Recently Closed did not open")
    return
  }
  #expect(spaceID == activeSpaceID)
}

@Test @MainActor func showAllHistoryCommandOpensTheHistoryLibrarySection() {
  let store = BrowserStore()

  NativeBrowserHost.showAllHistory(in: store)

  guard case .library(_, let section) = store.sheet else {
    Issue.record("Show All History did not open the library")
    return
  }
  #expect(section == .history)
}

@Test func showAllHistoryCommandUsesItsStandardTitleAndShortcut() {
  #expect(BrowserMenuCommand.showAllHistoryTitle == "Show All History")
  #expect(ShortcutCatalog.shortcut(for: .history)?.key == "y")
  #expect(ShortcutCatalog.shortcut(for: .history)?.modifiers == .command)
}

@Test @MainActor func fullScreenCommandTitleTracksItsToggleState() {
  #expect(NativeBrowserHost.fullScreenTitle(isFullScreen: false) == "Enter Full Screen")
  #expect(NativeBrowserHost.fullScreenTitle(isFullScreen: true) == "Exit Full Screen")
}

@Test @MainActor func backMenuCommandRoutesOnlyWhenTheSelectedPageCanGoBack() {
  let tabID = UUID()
  var routedTab: String?
  #expect(
    NativeBrowserHost.routeBack(tabID: tabID, canGoBack: true) { routedTab = $0 })
  #expect(routedTab == tabID.uuidString)
  #expect(!NativeBrowserHost.routeBack(tabID: tabID, canGoBack: false) { routedTab = $0 })
  #expect(!NativeBrowserHost.routeBack(tabID: nil, canGoBack: true) { routedTab = $0 })
}

@Test @MainActor func forwardMenuCommandRoutesOnlyWhenTheSelectedPageCanGoForward() {
  let tabID = UUID()
  var routedTab: String?
  #expect(
    NativeBrowserHost.routeForward(tabID: tabID, canGoForward: true) { routedTab = $0 })
  #expect(routedTab == tabID.uuidString)
  #expect(!NativeBrowserHost.routeForward(tabID: tabID, canGoForward: false) { routedTab = $0 })
  #expect(!NativeBrowserHost.routeForward(tabID: nil, canGoForward: true) { routedTab = $0 })
  #expect(routedTab == tabID.uuidString)
}

@Test @MainActor func nativeMenuRetainsKeyEquivalentsAndEditResponderChain() {
  let application = NSApplication.shared
  let menu = NativeBrowserHost.makeMenu(target: application)
  let items = menu.items.compactMap(\.submenu).flatMap(\.items)
  func item(_ title: String) -> NSMenuItem? { items.first { $0.title == title } }

  #expect(item("New window") == nil)
  #expect(!items.contains { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command })
  #expect(item("New Private Window")?.keyEquivalent == "n")
  #expect(item("New Private Window")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("New tab")?.keyEquivalent == "t")
  #expect(item(CommandPanel.searchPrompt)?.keyEquivalent == "l")
  #expect(item("Reopen last closed tab")?.keyEquivalent == "t")
  #expect(item("Reopen last closed tab")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("Reopen Last Closed Window")?.keyEquivalent.isEmpty == true)
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
  #expect(item("Emoji & Symbols")?.action == #selector(NSApplication.orderFrontCharacterPalette(_:)))
  #expect(item("Emoji & Symbols")?.keyEquivalent == "e")
  #expect(item("Emoji & Symbols")?.keyEquivalentModifierMask == .function)
  #expect(item("Emoji & Symbols")?.target == nil)
  #expect(
    ShortcutCatalog(menu: menu).entries.first { $0.title == "Emoji & Symbols" }?.displayKeys
      == "fn-E")
}

@Test @MainActor func functionEStaysOnTheSystemResponderChainWithPageFocus() {
  let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let page = ChromiumPageContainerView()
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
    windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
    isARepeat: false, keyCode: 14)!

  #expect(!ShortcutPageRouting.route(event, menu: menu, responder: page))
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
