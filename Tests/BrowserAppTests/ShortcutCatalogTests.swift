// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Test func clearHistoryShortcutDisplaysTheDeleteKey() {
  #expect(ShortcutCatalog.displayKeys(for: .clearHistory) == "⇧⌘⌫")
}

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
  var invoked: [String] = []
  @objc func invoke(_ sender: NSMenuItem?) {
    invoked.append(sender?.title ?? "")
  }
}

@Test @MainActor func disabledMenuShortcutDoesNotInvokeItsAction() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let menu = NSMenu()
  let group = NSMenuItem()
  let section = NSMenu(title: "File")
  let item = NSMenuItem(
    title: "Unavailable", action: #selector(ShortcutTestTarget.invoke(_:)), keyEquivalent: "u")
  item.target = target
  item.representedObject = "unavailable"
  item.isEnabled = false
  section.addItem(item)
  group.submenu = section
  menu.addItem(group)
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u",
    isARepeat: false, keyCode: 32)!

  #expect(!ShortcutPageRouting.route(event, menu: menu, responder: NSView()))
  #expect(target.invoked.isEmpty)
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
  #expect(target.invoked == ["Test"])
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
  #expect(ShortcutPageRouting.route(event, menu: menu, responder: NSView()))
}

@Test @MainActor func shiftedQuestionMarkRoutesHelpWithPageFocus() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let menu = NSMenu()
  let group = NSMenuItem()
  let help = NSMenu(title: "Help")
  let item = NSMenuItem(
    title: "Help", action: #selector(ShortcutTestTarget.invoke(_:)), keyEquivalent: "?")
  item.keyEquivalentModifierMask = .command
  item.target = target
  item.representedObject = BrowserMenuCommand.help.rawValue
  help.addItem(item)
  group.submenu = help
  menu.addItem(group)
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
    timestamp: 0, windowNumber: 0, context: nil, characters: "?",
    charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)!
  let container = ChromiumPageContainerView()
  let page = ShortcutFocusableView()
  container.attach(page)
  #expect(ShortcutPageRouting.route(event, menu: menu, responder: page))
  #expect(target.invoked == ["Help"])
  target.invoked.removeAll()
  let unshifted = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "/",
    charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)!
  #expect(!ShortcutPageRouting.route(unshifted, menu: menu, responder: page))
  #expect(target.invoked.isEmpty)
}

@Test @MainActor func typingWithoutCommandControlOrOptionIsNeverRoutedToMenus() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let menu = NSMenu()
  let group = NSMenuItem()
  let section = NSMenu(title: "Edit")
  let emoji = NSMenuItem(
    title: "Emoji & Symbols", action: #selector(ShortcutTestTarget.invoke(_:)), keyEquivalent: "e")
  emoji.keyEquivalentModifierMask = .function
  emoji.target = target
  section.addItem(emoji)
  group.submenu = section
  menu.addItem(group)
  let field = NSTextField()
  let plain = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
    isARepeat: false, keyCode: 14)!
  #expect(!ShortcutPageRouting.route(plain, menu: menu, responder: field))
  #expect(target.invoked.isEmpty)
  let withFunction = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .function,
    timestamp: 0, windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
    isARepeat: false, keyCode: 14)!
  #expect(!ShortcutPageRouting.route(withFunction, menu: menu, responder: field))
  #expect(target.invoked.isEmpty)
}

@Test @MainActor func everyAssignedMenuShortcutWorksWithPageFocus() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let source = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let menu = shortcutTestMenu(copying: source, target: target)
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

  let shortcuts = menu.items.compactMap(\.submenu).flatMap { section in
    section.items.filter { !$0.keyEquivalent.isEmpty }
  }
  #expect(!shortcuts.isEmpty)
  var routed: [String] = []
  for item in shortcuts {
    let event = shortcutEvent(for: item)
    let section = menuSection(for: item, in: menu)
    let isPageEditingShortcut =
      ShortcutCatalog.isEditMenu(
        identifier: section.identifier?.rawValue, title: section.title)
      && !(item.representedObject is String)
    let handled = ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder)
    if isPageEditingShortcut {
      #expect(!handled, "Edit shortcut should remain available to page editing: \(item.title)")
      #expect(target.invoked.isEmpty)
    } else {
      #expect(handled, "Page focus did not route \(item.title)")
      #expect(target.invoked == [item.title])
      routed.append(item.title)
    }
    target.invoked.removeAll()
  }
  #expect(
    routed.count
      == shortcuts.filter {
        let section = menuSection(for: $0, in: menu)
        return !ShortcutCatalog.isEditMenu(
          identifier: section.identifier?.rawValue, title: section.title)
          || $0.representedObject is String
      }.count)
}

@Test @MainActor func everyAssignedMenuShortcutWorksWithSidebarFocus() {
  _ = NSApplication.shared
  let target = ShortcutTestTarget()
  let menu = shortcutTestMenu(
    copying: NativeBrowserHost.makeMenu(target: NSApplication.shared), target: target)
  let sidebar = ShortcutFocusableView()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = sidebar
  #expect(window.makeFirstResponder(sidebar))
  #expect(window.firstResponder === sidebar)
  let shortcuts = menu.items.compactMap(\.submenu).flatMap { section in
    section.items.filter { !$0.keyEquivalent.isEmpty }
  }
  #expect(!shortcuts.isEmpty)
  for item in shortcuts {
    let event = shortcutEvent(for: item)
    if item.keyEquivalentModifierMask.contains(.function) || item.title == "Emoji & Symbols" {
      #expect(!ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder))
      #expect(target.invoked.isEmpty)
      continue
    }
    #expect(ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder))
    #expect(target.invoked == [item.title])
    target.invoked.removeAll()
  }
}

@MainActor private func menuSection(for item: NSMenuItem, in menu: NSMenu) -> NSMenu {
  menu.items.compactMap(\.submenu).first { $0.items.contains { $0 === item } }!
}

@MainActor private func shortcutTestMenu(copying source: NSMenu, target: ShortcutTestTarget)
  -> NSMenu
{
  let menu = NativeBrowserMenu()
  for sourceGroup in source.items {
    guard let sourceSection = sourceGroup.submenu else { continue }
    let group = NSMenuItem()
    let section = NSMenu(title: sourceSection.title)
    section.identifier = sourceSection.identifier
    for sourceItem in sourceSection.items {
      if sourceItem.isSeparatorItem {
        section.addItem(.separator())
        continue
      }
      let item = NSMenuItem(
        title: sourceItem.title, action: #selector(ShortcutTestTarget.invoke(_:)),
        keyEquivalent: sourceItem.keyEquivalent)
      item.identifier = sourceItem.identifier
      item.target = target
      item.representedObject = sourceItem.representedObject
      item.keyEquivalentModifierMask = sourceItem.keyEquivalentModifierMask
      section.addItem(item)
    }
    group.submenu = section
    menu.addItem(group)
  }
  return menu
}

private func shortcutEvent(for item: NSMenuItem) -> NSEvent {
  let key = item.keyEquivalent
  var modifiers = item.keyEquivalentModifierMask
  if key != key.lowercased() { modifiers.insert(.shift) }
  let characters = modifiers.contains(.shift) ? key.uppercased() : key
  let charactersIgnoringModifiers = key.lowercased()
  let keyCode: UInt16 =
    switch key.lowercased() {
    case "a": 0
    case "b": 11
    case "c": 8
    case "d": 2
    case "e": 14
    case "f": 3
    case "g": 5
    case "h": 4
    case "i": 34
    case "j": 38
    case "k": 40
    case "l": 37
    case "m": 46
    case "n": 45
    case "q": 12
    case "r": 15
    case "s": 1
    case "t": 17
    case "v": 9
    case "w": 13
    case "x": 7
    case "y": 16
    case "z": 6
    case ",": 43
    case "?": 44
    case "=": 24
    case "←": 123
    case "→": 124
    default: 0
    }
  return NSEvent.keyEvent(
    with: .keyDown, location: .zero,
    modifierFlags: modifiers,
    timestamp: 0, windowNumber: 0, context: nil,
    characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
    isARepeat: false, keyCode: keyCode)!
}

@Test @MainActor func normalNewWindowUsesCommandNAndPreservesOtherWindowShortcuts() {
  let entries = ShortcutCatalog.installed().entries
  #expect(entries.contains { $0.command == "newWindow" && $0.key == "n" && $0.modifiers == .command })
  #expect(LauncherCommands.catalog.contains { $0.id == "newWindow" })
  #expect(LauncherCommands.catalog.contains { $0.id == "newPrivateWindow" })
  #expect(LauncherCommands.catalog.contains { $0.id == "newMiniWindow" })
  // The native File menu owns Command-N, keeping Chromium from opening an untracked window.
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
    isARepeat: false, keyCode: 45)!
  let target = NewWindowMenuTarget()
  let menu = NativeBrowserHost.makeMenu(target: target)
  #expect(menu.performKeyEquivalent(with: event))
  #expect(target.invoked == ["newWindow"])
  for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option]] {
    let retained = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "n",
      charactersIgnoringModifiers: "n",
      isARepeat: false, keyCode: 45)!
    #expect(menu.performKeyEquivalent(with: retained))
  }
  #expect(target.invoked == ["newWindow", "newPrivateWindow", "newMiniWindow"])
}

@MainActor private final class NewWindowMenuTarget: NSObject {
  var invoked: [String] = []
  @objc func menuAction(_ sender: NSMenuItem) {
    invoked.append(sender.representedObject as? String ?? sender.title)
  }
}
