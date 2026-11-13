// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Test @MainActor func commandOptionArrowShortcutsCycleTabsInBothDirections() {
  let store = BrowserStore()
  for index in 1...3 {
    store.perform(.open(URL(string: "https://tab-arrow\(index).example")!))
  }
  let tabs = store.session.selectedSpace.tabs
  store.selectTabByShortcutIndex(0)

  #expect(NextTabShortcutRouting.route(event(keyCode: 124), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[1].id)
  #expect(NextTabShortcutRouting.route(event(keyCode: 123), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[0].id)

  store.selectTabByShortcutIndex(0)
  #expect(NextTabShortcutRouting.route(event(keyCode: 123), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[2].id)
  #expect(NextTabShortcutRouting.route(event(keyCode: 124), store: store))
  #expect(store.session.selectedSpace.selectedTabID == tabs[0].id)
}

@Test @MainActor func commandOptionArrowShortcutsRejectOtherModifiersAndKeyUp() {
  let store = BrowserStore()
  store.perform(.open(URL(string: "https://arrow-one.example")!))
  store.perform(.open(URL(string: "https://arrow-two.example")!))
  let selected = store.session.selectedSpace.selectedTabID

  for keyCode: UInt16 in [123, 124] {
    for modifiers in [
      NSEvent.ModifierFlags(), .command, [.command, .option, .shift],
      [.command, .option, .control],
    ] {
      #expect(
        !NextTabShortcutRouting.route(
          event(keyCode: keyCode, modifiers: modifiers), store: store))
    }
    #expect(!NextTabShortcutRouting.route(event(keyCode: keyCode, type: .keyUp), store: store))
  }
  #expect(store.session.selectedSpace.selectedTabID == selected)
}

private func event(
  keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [.command, .option],
  type: NSEvent.EventType = .keyDown
) -> NSEvent {
  NSEvent.keyEvent(
    with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
    isARepeat: false, keyCode: keyCode)!
}
