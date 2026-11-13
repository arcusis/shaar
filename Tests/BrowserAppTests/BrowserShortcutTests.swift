// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Test func developerToolsReservesOnlyOptionCommandI() {
  #expect(ARCReservedBrowserShortcut("i", [.command, .option]))
  #expect(ARCReservedBrowserShortcut("I", [.command, .option, .capsLock]))
  #expect(!ARCReservedBrowserShortcut("i", .command))
  #expect(ARCReservedBrowserShortcut("i", [.command, .option, .shift]))
  #expect(!ARCReservedBrowserShortcut("i", [.command, .option, .control]))
  #expect(ShortcutCatalog.displayKeys(for: .developerTools) == "⌥⌘I")
  #expect(ShortcutCatalog.displayKeys(for: .chromiumDeveloperTools) == "⌥⇧⌘I")
  #expect(ShaarDevToolsShortcut.isF12(keyCode: 111, modifiers: []))
  #expect(ShaarDevToolsShortcut.isF12(keyCode: 111, modifiers: [.function]))
  #expect(!ShaarDevToolsShortcut.isF12(keyCode: 111, modifiers: [.command]))
  #expect(
    ShaarDevToolsShortcut.isDirectChromiumShortcut(
      keyCode: 34, modifiers: [.command, .option, .shift]))
  #expect(
    !ShaarDevToolsShortcut.isDirectChromiumShortcut(keyCode: 34, modifiers: [.command, .option]))
  #expect(!ShaarDevToolsShortcut.isF12(keyCode: 110, modifiers: []))
  #expect(
    NSImage(
      systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
      != nil)
}

@Test func browserShortcutsDoNotStealBitwardenAutofillOrOtherModifierVariants() {
  #expect(ARCReservedBrowserShortcut("l", .command))
  #expect(ARCReservedBrowserShortcut("t", .command))
  #expect(ARCReservedBrowserShortcut(",", .command))
  #expect(ARCReservedBrowserShortcut("r", [.command, .capsLock]))
  #expect(!ARCReservedBrowserShortcut("L", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .control]))
  #expect(!ARCReservedBrowserShortcut("l", []))
  #expect(!ARCReservedBrowserShortcut(",", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut(",", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut(",", [.command, .control]))
}

@Test func nativeSpaceShortcutsRequireTheExactControlOptionChord() {
  #expect(ARCReservedBrowserShortcut("]", [.control, .option]))
  #expect(ARCReservedBrowserShortcut("[", [.control, .option]))
  #expect(!ARCReservedBrowserShortcut("]", [.control, .option, .shift]))
  #expect(!ARCReservedBrowserShortcut("]", .command))
}

@Test func findShortcutsReserveOnlyTheNativeFindChords() {
  #expect(ARCReservedBrowserShortcut("f", .command))
  #expect(ARCReservedBrowserShortcut("g", .command))
  #expect(ARCReservedBrowserShortcut("G", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("f", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("g", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("g", [.command, .control]))
  #expect(!ARCReservedBrowserShortcut("g", []))
}

@Test @MainActor func commandNumberRoutesToTheMatchingTabAndNineSelectsTheLast() throws {
  let store = BrowserStore()
  for index in 1...10 {
    store.perform(.open(URL(string: "https://tab\(index).example")!))
  }
  let tabs = store.session.selectedSpace.tabs
  #expect(tabs.count == 10)

  func event(_ number: String) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: number, charactersIgnoringModifiers: number,
      isARepeat: false, keyCode: 0)!
  }

  #expect(TabNumberShortcutRouting.route(event("2"), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[1].id)
  #expect(TabNumberShortcutRouting.route(event("9"), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs.last?.id)
  #expect(!TabNumberShortcutRouting.route(event("0"), store: store))
}

@Test @MainActor func controlTabCyclesToTheNextTabAndWraps() throws {
  let store = BrowserStore()
  for index in 1...3 {
    store.perform(.open(URL(string: "https://cycle\(index).example")!))
  }
  let tabs = store.session.selectedSpace.tabs
  store.selectTabByShortcutIndex(0)

  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
    windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
    isARepeat: false, keyCode: 48)!
  #expect(NextTabShortcutRouting.route(event, store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[1].id)
  store.selectTabByShortcutIndex(2)
  #expect(NextTabShortcutRouting.route(event, store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[0].id)
}

@Test @MainActor func controlTabFollowsNativeOrderAfterFolderMoves() throws {
  var session = BrowserSession.fresh()
  let spaceID = session.selectedSpaceID
  let first = session.open(URL(string: "https://cycle-folder-first.example")!)!
  let second = session.open(URL(string: "https://cycle-folder-second.example")!)!
  let third = session.open(URL(string: "https://cycle-folder-third.example")!)!
  let folderOne = session.addFolder(name: "One", in: spaceID)!
  let folderTwo = session.addFolder(name: "Two", in: spaceID)!
  let movedFirst = session.moveTab(first, from: spaceID, to: spaceID, folderID: folderOne)
  let movedSecond = session.moveTab(second, from: spaceID, to: spaceID, folderID: folderTwo)
  #expect(movedFirst && movedSecond)
  #expect(session.selectedSpace.orderedTabs.map(\.id) == [first, second, third])
  session.selectTab(third, in: spaceID)
  let store = BrowserStore(session: session)

  #expect(store.selectAdjacentTab(by: 1))
  #expect(store.session.selectedPage?.tab.id == first)
}

@Test @MainActor func controlTabRejectsAdditionalModifiersAndKeyUp() throws {
  let store = BrowserStore()
  store.perform(.open(URL(string: "https://next-one.example")!))
  store.perform(.open(URL(string: "https://next-two.example")!))
  let selected = store.session.selectedSpace.selectedTabID

  func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
      isARepeat: false, keyCode: 48)!
  }

  for modifiers in [
    NSEvent.ModifierFlags(), .control.union(.shift), .control.union(.option),
    .control.union(.command),
  ] {
    #expect(!NextTabShortcutRouting.route(event(.keyDown, modifiers), store: store))
  }
  #expect(!NextTabShortcutRouting.route(event(.keyUp, .control), store: store))
  #expect(store.session.selectedSpace.selectedTabID == selected)
}

@Test @MainActor func controlShiftTabCyclesToThePreviousTabAndWraps() throws {
  let store = BrowserStore()
  for index in 1...3 { store.perform(.open(URL(string: "https://previous\(index).example")!)) }
  let tabs = store.session.selectedSpace.tabs
  store.selectTabByShortcutIndex(0)
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
    windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
    isARepeat: false, keyCode: 48)!
  #expect(PreviousTabShortcutRouting.route(event, store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[2].id)
  store.selectTabByShortcutIndex(1)
  #expect(PreviousTabShortcutRouting.route(event, store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[0].id)
}

@Test @MainActor func controlShiftTabRejectsAdditionalModifiersAndKeyUp() throws {
  let store = BrowserStore()
  store.perform(.open(URL(string: "https://previous-one.example")!))
  store.perform(.open(URL(string: "https://previous-two.example")!))
  let selected = store.session.selectedSpace.selectedTabID
  func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
      isARepeat: false, keyCode: 48)!
  }
  for modifiers in [NSEvent.ModifierFlags(), .control, .control.union(.command), .control.union(.shift).union(.option)] {
    #expect(!PreviousTabShortcutRouting.route(event(.keyDown, modifiers), store: store))
  }
  #expect(!PreviousTabShortcutRouting.route(event(.keyUp, [.control, .shift]), store: store))
  #expect(store.session.selectedSpace.selectedTabID == selected)
}

@Test @MainActor func commandNumberRoutingRejectsModifiedVariantsAndKeyUp() throws {
  let store = BrowserStore()
  store.perform(.open(URL(string: "https://one.example")!))
  store.perform(.open(URL(string: "https://two.example")!))
  let selected = store.session.selectedSpace.selectedTabID
  func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
      isARepeat: false, keyCode: 18)!
  }
  for modifiers in [NSEvent.ModifierFlags(), .command.union(.shift), .command.union(.option), .command.union(.control)] {
    #expect(!TabNumberShortcutRouting.route(event(.keyDown, modifiers), store: store))
  }
  #expect(!TabNumberShortcutRouting.route(event(.keyUp, .command), store: store))
  #expect(store.session.selectedSpace.selectedTabID == selected)
}

@Test func downloadsShortcutDoesNotReserveOtherCommandJVariants() {
  #expect(ARCReservedBrowserShortcut("J", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("j", .command))
  #expect(!ARCReservedBrowserShortcut("j", [.command, .shift, .option]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .shift]))
}

@Test func reopenShortcutRequiresExactCommandShiftT() {
  #expect(ARCReservedBrowserShortcut("T", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("t", [.command, .shift, .option]))
  #expect(!ARCReservedBrowserShortcut("t", [.command, .control]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .shift]))
}

@Test func libraryShortcutsReserveOnlyCommandDAndCommandY() {
  #expect(ARCReservedBrowserShortcut("d", .command))
  #expect(ARCReservedBrowserShortcut("y", .command))
  #expect(!ARCReservedBrowserShortcut("d", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("y", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .shift]))
}
@Test func nativeWindowShortcutsReserveOnlyTheirExactModifiers() {
  #expect(ARCReservedBrowserShortcut("n", .command))
  #expect(ARCReservedBrowserShortcut("W", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("n", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("n", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .shift]))
}

@Test func hardReloadReservesOnlyCommandShiftR() {
  #expect(ARCReservedBrowserShortcut("R", [.command, .shift]))
  #expect(ARCReservedBrowserShortcut("r", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("r", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("r", [.command, .shift, .option]))
}
