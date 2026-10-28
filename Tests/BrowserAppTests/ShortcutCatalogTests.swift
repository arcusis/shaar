import AppKit
import Testing

@testable import ArcusisBrowser

@Test @MainActor func shortcutCatalogContainsEveryMenuKeyEquivalent() {
  let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
  let expected = menu.items.compactMap(\.submenu).flatMap { section in
    section.items.filter { !$0.keyEquivalent.isEmpty || $0.representedObject is String }.map { "\(section.title):\($0.title)" }
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
  let item = NSMenuItem(title: "Test", action: #selector(ShortcutTestTarget.invoke(_:)), keyEquivalent: "t")
  item.target = target
  item.representedObject = "test"
  section.addItem(item)
  group.submenu = section
  menu.addItem(group)
  let container = ChromiumPageContainerView()
  let page = ShortcutFocusableView()
  container.attach(page)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = container
  #expect(window.makeFirstResponder(page))
  #expect(window.firstResponder === page)
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t",
    isARepeat: false, keyCode: 17)!
  #expect(ShortcutPageRouting.route(event, menu: menu, responder: window.firstResponder))
  #expect(target.invoked)
  let editGroup = NSMenuItem()
  let edit = NSMenu(title: "Edit")
  edit.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
  editGroup.submenu = edit
  menu.addItem(editGroup)
  let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
    isARepeat: false, keyCode: 8)!
  #expect(!ShortcutPageRouting.route(copy, menu: menu, responder: window.firstResponder))
  #expect(!ShortcutPageRouting.route(event, menu: menu, responder: NSView()))
}
