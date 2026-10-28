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

  init(menu: NSMenu) {
    entries = menu.items.compactMap(\.submenu).flatMap { section in
      section.items.compactMap { item in
        guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty || item.representedObject is String else { return nil }
        return Entry(menu: section.title, title: item.title, key: item.keyEquivalent,
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
        let itemFlags = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        return !item.keyEquivalent.isEmpty && item.keyEquivalent.lowercased() == key && itemFlags == flags
      }
    }
    return matches && menu.performKeyEquivalent(with: event)
  }
}
