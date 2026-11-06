// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Test @MainActor func everyMenuCommandHasUniqueShortcutAndCatalogListsAllShortcuts() {
  let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let items = menu.items.compactMap(\.submenu).flatMap(\.items)
  let commands = items.compactMap { item -> (BrowserMenuCommand, NSMenuItem)? in
    guard let rawValue = item.representedObject as? String,
      let command = BrowserMenuCommand(rawValue: rawValue)
    else { return nil }
    return (command, item)
  }
  #expect(Set(commands.map(\.0)) == Set(BrowserMenuCommand.allCases))
  #expect(commands.first { $0.0 == .sharePage }?.1.keyEquivalent == "")
  let actionableItems = items.filter {
    !$0.isSeparatorItem && $0.action != nil && $0.submenu == nil
      && !ShortcutCatalog.unassignedTitles.contains($0.title)
  }
  #expect(actionableItems.allSatisfy { !$0.keyEquivalent.isEmpty })
  let shortcutKeys = actionableItems.map {
    var modifiers = $0.keyEquivalentModifierMask
    if $0.keyEquivalent != $0.keyEquivalent.lowercased() { modifiers.insert(.shift) }
    return "\($0.keyEquivalent.lowercased()):\(modifiers.rawValue)"
  }
  #expect(Set(shortcutKeys).count == shortcutKeys.count)

  let catalog = ShortcutCatalog(menu: menu)
  #expect(Set(catalog.entries.map(\.title)).isSuperset(of: Set(commands.map { $0.1.title })))
  #expect(catalog.entries.contains { $0.title == "New Folder" && $0.displayKeys == "⌃⌘N" })
}

@Test @MainActor func shortcutSettingsSearchFindsTitleWithoutTypingAccents() {
  let menu = NSMenu()
  let group = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
  let submenu = NSMenu(title: "File")
  submenu.addItem(NSMenuItem(title: "Résumé", action: nil, keyEquivalent: "r"))
  group.submenu = submenu
  menu.addItem(group)
  let catalog = ShortcutCatalog(menu: menu)

  #expect(catalog.matching("resume").map(\.title) == ["Résumé"])
  #expect(catalog.matching("missing").isEmpty)
}
