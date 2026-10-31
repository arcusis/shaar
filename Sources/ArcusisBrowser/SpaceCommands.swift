// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum SpaceShortcut {
  static func key(forIndex index: Int) -> Character? {
    guard (0..<9).contains(index) else { return nil }
    return Character(String(index + 1))
  }
}

struct SpaceCommands: Commands {
  let store: BrowserStore

  var body: some Commands {
    CommandMenu("Spaces") {
      Button("New space…") { store.spaceEditor = .create }
        .keyboardShortcut("n", modifiers: [.command, .option])
      Button("Edit current space…") { store.spaceEditor = .edit(store.session.selectedSpaceID) }
      Divider()
      Button("Previous space") { store.cycleSpace(by: -1) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      Button("Next space") { store.cycleSpace(by: 1) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
      Divider()
      ForEach(Array(store.session.spaces.enumerated()), id: \.element.id) { index, space in
        if let key = SpaceShortcut.key(forIndex: index) {
          spaceButton(space.id, name: space.name)
            .keyboardShortcut(KeyEquivalent(key), modifiers: .control)
        } else {
          spaceButton(space.id, name: space.name)
        }
      }
    }
    CommandMenu("Page") {
      Button("Split View") { store.splitSelectedTab() }
        .keyboardShortcut("=", modifiers: [.control, .shift])
        .disabled(store.session.selectedSpace.tabs.count < 2)
      Button("Copy URL") {
        guard let url = store.session.selectedPage?.tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CleanLink.clean(url).absoluteString, forType: .string)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(store.session.selectedPage == nil)
    }
  }

  private func spaceButton(_ id: UUID, name: String) -> some View {
    Button {
      store.perform(.space(id))
    } label: {
      if store.session.selectedSpaceID == id {
        Label(name, systemImage: "checkmark")
      } else {
        Text(name)
      }
    }
  }
}
