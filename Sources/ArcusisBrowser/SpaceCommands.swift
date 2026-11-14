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
  static let newSpaceShortcut = KeyboardShortcut("S", modifiers: [.command, .shift])
  static let splitViewShortcut = KeyboardShortcut("=", modifiers: [.control, .shift])
  static let copyURLShortcut = KeyboardShortcut("c", modifiers: [.command, .shift])
  let store: BrowserStore

  var body: some Commands {
    CommandMenu(ShellL10n.string("Spaces")) {
      Button(ShellL10n.string("New space…")) { store.spaceEditor = .create }
        .keyboardShortcut(Self.newSpaceShortcut)
      Button(ShellL10n.string("Edit current space…")) {
        store.spaceEditor = .edit(store.session.selectedSpaceID)
      }
      Divider()
      Button(ShellL10n.string("Previous space")) { store.cycleSpace(by: -1) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(!store.canCycleSpace)
      Button(ShellL10n.string("Next space")) { store.cycleSpace(by: 1) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(!store.canCycleSpace)
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
    CommandMenu(ShellL10n.string("Page")) {
      Button(ShellL10n.string("Split View")) { store.splitSelectedTab() }
        .keyboardShortcut(Self.splitViewShortcut)
        .disabled(!store.canSplitSelectedTab)
      Button(ShellL10n.string("Copy URL")) {
        guard let url = store.session.selectedPage?.tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CleanLink.clean(url).absoluteString, forType: .string)
      }
      .keyboardShortcut(Self.copyURLShortcut)
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
