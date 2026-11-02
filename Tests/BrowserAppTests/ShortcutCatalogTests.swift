// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Test @MainActor func shortcutCatalogContainsEveryMenuKeyEquivalent() {
  let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let expected = menu.items.compactMap(\.submenu).flatMap { section in
    section.items.filter { !$0.keyEquivalent.isEmpty || $0.representedObject is String }.map {
      "\(section.title):\($0.title)"
    }
  }
  let actual = ShortcutCatalog(menu: menu).entries.map { "\($0.menu):\($0.title)" }
  #expect(actual == expected)
}

@MainActor private final class ShortcutTestTarget: NSObject {
  var invoked = false
  @objc func invoke(_ sender: Any?) { invoked = true }
}

private final class ShortcutFocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@Test @MainActor func pageResponderRoutesMenuEquivalentAndLeavesEditingToPage() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let menu = NSMenu()
  let group = NSMenuItem()
  let section = NSMenu(title: "File")
  let item = NSMenuItem(
    title: "Test", action: #selector(ShortcutTestTarget.invoke(_:)), keyEquivalent: "t")
  item.target = target
  item.representedObject = "test"
  section.addItem(item)
  group.submenu = section
  menu.addItem(group)
  let container = ChromiumPageContainerView()
  let page = ShortcutFocusableView()
  container.attach(page)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = container
  #expect(window.makeFirstResponder(page))
  #expect(window.firstResponder === page)
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t",
    isARepeat: false, keyCode: 17)!
  #expect(ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder))
  #expect(target.invoked)
  let editGroup = NSMenuItem()
  let edit = NSMenu(title: "Edit")
  edit.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
  editGroup.submenu = edit
  menu.addItem(editGroup)
  let copy = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
    isARepeat: false, keyCode: 8)!
  #expect(!ShortcutPageRouting.route(copy, menu: menu, responder: window.firstResponder))
  #expect(!ShortcutPageRouting.route(event, menu: menu, responder: NSView()))
}

@Test @MainActor func normalNewWindowIsAbsentFromShortcutSettingsAndLauncher() {
  let entries = ShortcutCatalog.installed().entries
  #expect(!entries.contains { $0.command == "newWindow" })
  #expect(!entries.contains { $0.key.lowercased() == "n" && $0.modifiers == .command })
  #expect(!LauncherCommands.catalog.contains { $0.id == "newWindow" })
  #expect(LauncherCommands.catalog.contains { $0.id == "newPrivateWindow" })
  #expect(LauncherCommands.catalog.contains { $0.id == "newMiniWindow" })
  // Chromium must not run its built-in New Window command when no menu item handles Command-N.
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
    isARepeat: false, keyCode: 45)!
  let target = NewWindowMenuTarget()
  let menu = NativeBrowserHost.makeMenu(target: target)
  #expect(!menu.performKeyEquivalent(with: event))
  #expect(target.invoked.isEmpty)
  for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option]] {
    let retained = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "n",
      charactersIgnoringModifiers: "n",
      isARepeat: false, keyCode: 45)!
    #expect(menu.performKeyEquivalent(with: retained))
  }
  #expect(target.invoked == ["newPrivateWindow", "newMiniWindow"])
}

@MainActor private final class NewWindowMenuTarget: NSObject {
  var invoked: [String] = []
  @objc func menuAction(_ sender: NSMenuItem) {
    invoked.append(sender.representedObject as? String ?? sender.title)
  }
}
