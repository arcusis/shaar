import AppKit

struct ShortcutCatalog {
  struct Entry: Identifiable {
    let menu: String
    let title: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    var id: String { "\(menu):\(title):\(key):\(modifiers.rawValue)" }

    var displayKeys: String {
      if key.isEmpty { return "—" }
      var result = ""
      if modifiers.contains(.control) { result += "⌃" }
      if modifiers.contains(.option) { result += "⌥" }
      if modifiers.contains(.shift) || key != key.lowercased() { result += "⇧" }
      if modifiers.contains(.command) { result += "⌘" }
      switch key.unicodeScalars.first?.value {
      case UInt32(NSLeftArrowFunctionKey): result += "←"
      case UInt32(NSRightArrowFunctionKey): result += "→"
      default: result += key.uppercased()
      }
      return result
    }
  }

  let entries: [Entry]

  /// macOS leaves these standard items without shortcuts; web pages keep those keys.
  static let unassignedTitles: Set<String> = [
    "About Arcusis Browser", "Show All", "Bring All to Front",
  ]

  static func shortcut(for command: BrowserMenuCommand) -> (
    key: String, modifiers: NSEvent.ModifierFlags
  )? {
    switch command {
    case .newWindow: ("n", .command)
    case .newPrivateWindow: ("n", [.command, .shift])
    case .newMiniWindow: ("n", [.command, .option])
    case .newTab: ("t", .command)
    case .search: ("l", .command)
    case .closeWindow: ("w", [.command, .shift])
    case .find: ("f", .command)
    case .findNext: ("g", .command)
    case .findPrevious: ("g", [.command, .shift])
    case .sidebar: ("s", .command)
    case .reload: ("r", .command)
    case .newSpace: ("S", [.command, .shift])
    case .editSpace: ("s", [.command, .option])
    case .addFavorite: ("k", [.command, .option])
    // Command-Control-N avoids Command-Shift-N (Private Window) and Command-Option-N (Mini Window).
    case .createFolder: ("n", [.command, .control])
    case .nextSpace:
      (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option])
    case .previousSpace:
      (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option])
    case .splitView: ("=", [.control, .shift])
    case .closeTab: ("w", .command)
    case .reopenClosed: ("t", [.command, .shift])
    case .recentlyClosed: ("y", [.command, .option])
    case .bookmarkPage: ("d", .command)
    // Command-B stays with web editors for bold.
    case .bookmarks: ("b", [.command, .option])
    case .history: ("y", .command)
    case .downloads: ("j", [.command, .shift])
    case .extensions: ("e", [.command, .shift])
    case .zoomWindow: ("m", [.command, .control])
    case .bringAllToFront: nil
    case .help: ("?", .command)
    case .minimizeWindow: ("m", .command)
    case .settings: (",", .command)
    case .quit: ("q", .command)
    }
  }

  static func standardShortcut(for title: String) -> (
    key: String, modifiers: NSEvent.ModifierFlags
  )? {
    switch title {
    case "Hide Arcusis Browser": ("h", .command)
    case "Hide Others": ("h", [.command, .option])
    case "Undo": ("z", .command)
    case "Redo": ("Z", .command)
    case "Cut": ("x", .command)
    case "Copy": ("c", .command)
    case "Paste": ("v", .command)
    case "Select All": ("a", .command)
    case "Copy URL": ("c", [.command, .shift])
    default: nil
    }
  }

  init(menu: NSMenu) {
    entries = menu.items.compactMap(\.submenu).flatMap { section in
      section.items.compactMap { item in
        guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty || item.representedObject is String
        else { return nil }
        return Entry(
          menu: section.title, title: item.title, key: item.keyEquivalent,
          modifiers: item.keyEquivalentModifierMask)
      }
    }
  }
}

@MainActor
enum ShortcutPageRouting {
  static func route(_ event: NSEvent, menu: NSMenu, responder: NSResponder?) -> Bool {
    guard event.type == .keyDown, let view = responder as? NSView else { return false }
    var ancestor: NSView? = view
    while let current = ancestor, !(current is ChromiumPageContainerView) {
      ancestor = current.superview
    }
    guard ancestor != nil else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? "").lowercased()
    let matches = menu.items.compactMap(\.submenu).contains { section in
      section.items.contains { item in
        guard item.representedObject is String || section.title != "Edit" else { return false }
        let itemFlags = item.keyEquivalentModifierMask.intersection([
          .command, .option, .control, .shift,
        ])
        return !item.keyEquivalent.isEmpty && item.keyEquivalent.lowercased() == key
          && itemFlags == flags
      }
    }
    return matches && menu.performKeyEquivalent(with: event)
  }
}
