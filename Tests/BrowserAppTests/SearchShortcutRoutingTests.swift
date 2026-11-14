// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@Test @MainActor func commandOptionFRoutesToSearchInsteadOfFind() {
  let application = NSApplication.shared
  _ = application
  let target = SearchShortcutTestTarget()
  let menu = NSMenu()

  for (name, title, key, modifiers) in [
    ("Edit", "Find in Page", "f", NSEvent.ModifierFlags.command),
    ("File", "Search", "l", NSEvent.ModifierFlags.command),
  ] {
    let group = NSMenuItem()
    let section = NSMenu(title: name)
    section.identifier = NSUserInterfaceItemIdentifier(name)
    let item = NSMenuItem(
      title: title, action: #selector(SearchShortcutTestTarget.invoke(_:)), keyEquivalent: key)
    item.target = target
    item.representedObject = name == "File" ? BrowserMenuCommand.search.rawValue : "find"
    item.keyEquivalentModifierMask = modifiers
    section.addItem(item)
    group.submenu = section
    menu.addItem(group)
  }

  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
    windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
    isARepeat: false, keyCode: 3)!
  #expect(ShortcutPageRouting.route(event, menu: menu, responder: NSView()))
  #expect(target.invoked == [BrowserMenuCommand.search.rawValue])
}

@MainActor private final class SearchShortcutTestTarget: NSObject {
  var invoked: [String] = []

  @objc func invoke(_ sender: NSMenuItem) {
    invoked.append(sender.representedObject as? String ?? sender.title)
  }
}
