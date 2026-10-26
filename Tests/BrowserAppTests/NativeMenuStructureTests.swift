import AppKit
import Testing

@testable import ArcusisBrowser

@Test @MainActor func nativeMenusMatchArcGroupsAndRouteEveryImplementedCommandOnce() {
  let application = NSApplication.shared
  let menu = NativeBrowserHost.makeMenu(target: application)
  let groups = menu.items.compactMap(\.submenu)
  #expect(
    groups.map(\.title) == [
      "Arcusis Browser", "File", "Edit", "View", "Spaces", "Tabs", "Archive",
      "Extensions", "Window", "Help",
    ])

  let commandItems = groups.flatMap(\.items).compactMap { item -> (String, NSMenuItem)? in
    guard let command = item.representedObject as? String else { return nil }
    return (command, item)
  }
  #expect(Set(commandItems.map(\.0)) == Set(BrowserMenuCommand.allCases.map(\.rawValue)))
  #expect(commandItems.count == BrowserMenuCommand.allCases.count)

  func item(_ command: BrowserMenuCommand) -> NSMenuItem? {
    commandItems.first { $0.0 == command.rawValue }?.1
  }
  #expect(item(.newWindow)?.menu?.title == "File")
  #expect(item(.newPrivateWindow)?.menu?.title == "File")
  #expect(item(.closeWindow)?.menu?.title == "File")
  #expect(item(.find)?.menu?.title == "Edit")
  #expect(item(.reload)?.menu?.title == "View")
  #expect(item(.newSpace)?.menu?.title == "Spaces")
  #expect(item(.closeTab)?.menu?.title == "Tabs")
  #expect(item(.bookmarks)?.menu?.title == "Archive")
  #expect(item(.extensions)?.menu?.title == "Extensions")
  #expect(item(.minimizeWindow)?.menu?.title == "Window")
  #expect(item(.help)?.menu?.title == "Help")
}

@Test @MainActor func nativeMenuRetainsKeyEquivalentsAndEditResponderChain() {
  let application = NSApplication.shared
  let menu = NativeBrowserHost.makeMenu(target: application)
  let items = menu.items.compactMap(\.submenu).flatMap(\.items)
  func item(_ title: String) -> NSMenuItem? { items.first { $0.title == title } }

  #expect(item("New window")?.keyEquivalent == "n")
  #expect(item("New Private Window")?.keyEquivalent == "n")
  #expect(item("New Private Window")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("New tab")?.keyEquivalent == "t")
  #expect(item("Search or enter address")?.keyEquivalent == "l")
  #expect(item("Close tab")?.keyEquivalentModifierMask == .command)
  #expect(item("Close window")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("Find in Page…")?.keyEquivalent == "f")
  #expect(item("Next space")?.keyEquivalentModifierMask == [.control, .option])
  #expect(item("Downloads")?.keyEquivalentModifierMask == [.command, .shift])
  #expect(item("Undo")?.action == NSSelectorFromString("undo:"))
  #expect(item("Cut")?.action == NSSelectorFromString("cut:"))
  #expect(item("Copy")?.action == NSSelectorFromString("copy:"))
  #expect(item("Paste")?.action == NSSelectorFromString("paste:"))
  #expect(item("Select All")?.action == NSSelectorFromString("selectAll:"))
  #expect(item("Undo")?.target == nil && item("Paste")?.target == nil)
}
