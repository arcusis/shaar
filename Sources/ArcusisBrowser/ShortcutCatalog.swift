// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

struct ShortcutCatalog {
  static func isEditMenu(identifier: String?, title: String) -> Bool {
    identifier == "Edit" || title == "Edit"
  }

  struct Entry: Identifiable {
    let menu: String
    let title: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    /// The `BrowserMenuCommand` name for app commands; nil for standard AppKit items.
    var command: String?
    let englishMenu: String?
    let englishTitle: String?

    init(
      menu: String, title: String, key: String, modifiers: NSEvent.ModifierFlags,
      command: String? = nil, englishMenu: String? = nil, englishTitle: String? = nil
    ) {
      self.menu = menu
      self.title = title
      self.key = key
      self.modifiers = modifiers
      self.command = command
      self.englishMenu = englishMenu
      self.englishTitle = englishTitle
    }

    var id: String { "\(menu):\(title):\(key):\(modifiers.rawValue)" }
    var localizedMenu: String { SettingsL10n.string(menu) }
    var localizedTitle: String {
      let productName = ProductIdentity.name
      if title == "About \(productName)" {
        return SettingsL10n.format("About %@", .string(productName))
      }
      if title == "Hide \(productName)" {
        return SettingsL10n.format("Hide %@", .string(productName))
      }
      if title == "Quit \(productName)" {
        return SettingsL10n.format("Quit %@", .string(productName))
      }
      if title == "\(productName) Support" {
        return SettingsL10n.format("%@ Support", .string(productName))
      }
      return SettingsL10n.string(title)
    }

    var displayKeys: String {
      if key.isEmpty { return "—" }
      var result = ""
      if modifiers.contains(.function) { result += "fn-" }
      if modifiers.contains(.control) { result += "⌃" }
      if modifiers.contains(.option) { result += "⌥" }
      if modifiers.contains(.shift) || key != key.lowercased() { result += "⇧" }
      if modifiers.contains(.command) { result += "⌘" }
      switch key.unicodeScalars.first?.value {
      case UInt32(NSLeftArrowFunctionKey): result += "←"
      case UInt32(NSRightArrowFunctionKey): result += "→"
      case 0x08: result += "⌫"
      default: result += key.uppercased()
      }
      return result
    }
  }

  let entries: [Entry]

  func matching(_ search: String) -> [Entry] {
    guard !search.isEmpty else { return entries }
    return entries.filter { entry in
      let fields = [
        entry.localizedTitle, entry.localizedMenu, entry.displayKeys,
        entry.title, entry.menu, entry.englishTitle, entry.englishMenu,
      ].compactMap { $0 }
      return fields.contains { $0.localizedStandardContains(search) }
    }
  }

  /// These menu actions intentionally have no shortcut; web pages keep those keys.
  static let unassignedTitles: Set<String> = [
    "About \(ProductIdentity.name)", "Check for Updates…", "Show All", "Bring All to Front",
    "Share Page…",
  ]

  static func shortcut(for command: BrowserMenuCommand) -> (
    key: String, modifiers: NSEvent.ModifierFlags
  )? {
    switch command {
    case .newPrivateWindow: ("n", [.command, .shift])
    case .newMiniWindow: ("n", [.command, .option])
    case .newTab: ("t", .command)
    case .back: ("[", .command)
    case .forward: ("]", .command)
    case .search: ("l", .command)
    case .closeWindow: ("w", [.command, .shift])
    case .find: ("f", .command)
    case .findNext: ("g", .command)
    case .findPrevious: ("g", [.command, .shift])
    case .sidebar: ("s", .command)
    case .reload: ("r", .command)
    case .hardReload: ("r", [.command, .shift])
    case .developerTools: ("i", [.command, .option])
    // The View menu has one Developer Tools item. This chord stays on the key
    // monitor so Option-Shift-Command-I still opens the Chromium dock.
    case .chromiumDeveloperTools: ("i", [.command, .option, .shift])
    case .inspector: ("c", [.command, .option])
    case .inspectorSource: ("o", [.command, .option])
    case .inspectorAgentCopy: ("a", [.command, .option, .shift])
    case .inspectorCopy: ("c", [.command, .shift])
    case .newSpace: ("S", [.command, .shift])
    case .editSpace: ("s", [.command, .option])
    case .addFavorite: ("k", [.command, .option])
    // Command-Control-N avoids Command-Shift-N (Private Window) and Command-Option-N (Mini Window).
    case .createFolder: ("n", [.command, .control])
    case .nextSpace:
      (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option])
    case .previousSpace:
      (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option])
    case .nextWindow: ("`", .command)
    case .previousWindow: ("`", [.command, .shift])
    case .fullScreen: ("f", [.command, .control])
    case .splitView: ("=", [.control, .shift])
    case .closeTab: ("w", .command)
    case .reopenClosed: ("t", [.command, .shift])
    case .recentlyClosed: ("y", [.command, .option])
    case .bookmarkPage: ("d", .command)
    // Command-B stays with web editors for bold.
    case .bookmarks: ("b", [.command, .option])
    case .history: ("y", .command)
    case .clearHistory: ("\u{8}", [.command, .shift])
    case .downloads: ("j", [.command, .shift])
    case .extensions: ("e", [.command, .shift])
    case .zoomWindow: ("m", [.command, .control])
    case .bringAllToFront, .checkForUpdates, .sharePage, .reopenClosedWindow, .clearHistory: nil
    case .help: ("?", .command)
    case .minimizeWindow: ("m", .command)
    case .settings: (",", .command)
    case .quit: ("q", .command)
    }
  }

  /// Menu glyphs such as ⇧⌘R for a command's shortcut, or nil when it has none.
  static func displayKeys(for command: BrowserMenuCommand?) -> String? {
    guard let command, let shortcut = shortcut(for: command) else { return nil }
    return Entry(menu: "", title: "", key: shortcut.key, modifiers: shortcut.modifiers).displayKeys
  }

  static func standardShortcut(for title: String) -> (
    key: String, modifiers: NSEvent.ModifierFlags
  )? {
    switch title {
    case "Hide \(ProductIdentity.name)": ("h", .command)
    case "Hide Others": ("h", [.command, .option])
    case "Undo": ("z", .command)
    case "Redo": ("Z", .command)
    case "Cut": ("x", .command)
    case "Copy": ("c", .command)
    case "Paste": ("v", .command)
    case "Paste and Match Style": ("V", [.command, .option])
    case "Emoji & Symbols": ("e", .function)
    case "Select All": ("a", .command)
    case "Copy URL": ("c", [.command, .option, .shift])
    default: nil
    }
  }

  /// The catalog of the menu the app installs.
  @MainActor static func installed() -> ShortcutCatalog {
    ShortcutCatalog(menu: NativeBrowserHost.makeMenu(target: NSApplication.shared))
  }

  init(menu: NSMenu) {
    entries = menu.items.compactMap(\.submenu).flatMap { section in
      section.items.compactMap { item in
        guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty || item.representedObject is String
        else { return nil }
        let englishMenu = section.identifier?.rawValue
        let englishTitle = item.identifier?.rawValue
        return Entry(
          menu: section.title, title: item.title, key: item.keyEquivalent,
          modifiers: item.keyEquivalentModifierMask, command: item.representedObject as? String,
          englishMenu: englishMenu?.isEmpty == false ? englishMenu : nil,
          englishTitle: englishTitle?.isEmpty == false ? englishTitle : nil)
      }
    }
  }
}

enum ShaarDevToolsShortcut {
  static func isF12(_ event: NSEvent) -> Bool {
    isF12(keyCode: event.keyCode, modifiers: event.modifierFlags)
  }

  static func isF12(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    keyCode == 111 && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
  }

  static func isDirectChromiumShortcut(_ event: NSEvent) -> Bool {
    isDirectChromiumShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
  }

  /// Option-Shift-Command-I. ANSI I.
  static func isDirectChromiumShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let flags = modifiers.intersection([.command, .option, .control, .shift])
    return keyCode == 34 && flags == [.command, .option, .shift]
  }

}

@MainActor
enum ShortcutPageRouting {
  static func route(_ event: NSEvent, menu: NSMenu, responder: NSResponder?) -> Bool {
    guard event.type == .keyDown else { return false }
    var ancestor = (responder as? NSView)
    while let current = ancestor, !(current is ChromiumPageContainerView) {
      ancestor = current.superview
    }
    let pageHasFocus = ancestor != nil
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
    // Typing (no command, control or option) always belongs to the focused field. AppKit's
    // Edit > Emoji & Symbols is fn-E; once fn is masked off it would match a plain E keystroke.
    guard !flags.isDisjoint(with: [.command, .control, .option]) else { return false }
    let key = (event.charactersIgnoringModifiers ?? "").lowercased()
    let typedKey = (event.characters ?? "").lowercased()
    for section in menu.items.compactMap(\.submenu) {
      for item in section.items {
        let standardEditItem =
          !(item.representedObject is String)
          && ShortcutCatalog.isEditMenu(
            identifier: section.identifier?.rawValue, title: section.title)
        var itemFlags = item.keyEquivalentModifierMask.intersection([
          .command, .option, .control, .shift,
        ])
        if item.keyEquivalent != item.keyEquivalent.lowercased() { itemFlags.insert(.shift) }
        let itemKey = item.keyEquivalent.lowercased()
        // Punctuation such as ? is produced by Shift-/ on many keyboards. AppKit stores the
        // resulting symbol as the menu key equivalent, while this event's base key is /.
        let shiftedSymbol = flags.contains(.shift) && itemKey != key && itemKey == typedKey
        if shiftedSymbol { itemFlags.insert(.shift) }
        guard
          item.isEnabled && !itemKey.isEmpty && (itemKey == key || shiftedSymbol)
            && itemFlags == flags
        else { continue }
        if pageHasFocus && standardEditItem { return false }
        if let validator = item.target as? NSMenuItemValidation,
          !validator.validateMenuItem(item)
        {
          return false
        }
        guard let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
      }
    }
    return false
  }
}

@MainActor
enum TabNumberShortcutRouting {
  static func route(_ event: NSEvent, store: BrowserStore) -> Bool {
    guard event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
      let character = event.charactersIgnoringModifiers,
      let number = Int(character), (1...9).contains(number)
    else { return false }
    return store.selectNumberedPage(number)
  }
}

@MainActor
enum NextTabShortcutRouting {
  static func route(_ event: NSEvent, store: BrowserStore) -> Bool {
    guard event.type == .keyDown else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let offset: Int
    if event.keyCode == 48 && modifiers == .control {
      offset = 1
    } else if event.keyCode == 124 && modifiers == [.command, .option] {
      offset = 1
    } else if event.keyCode == 123 && modifiers == [.command, .option] {
      offset = -1
    } else if event.keyCode == 30 && modifiers == [.command, .shift] {
      offset = 1
    } else if event.keyCode == 33 && modifiers == [.command, .shift] {
      offset = -1
    } else { return false }
    return store.selectAdjacentTab(by: offset)
  }
}

@MainActor
enum PreviousTabShortcutRouting {
  static func route(_ event: NSEvent, store: BrowserStore) -> Bool {
    guard event.type == .keyDown, event.keyCode == 48,
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.control, .shift]
    else { return false }
    return store.selectAdjacentTab(by: -1)
  }
}
