// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

struct ShaarDevToolsShortcutRoutingTests {
  @Test func f12RoutesToShaarDeveloperTools() {
    #expect(ShaarDevToolsShortcut.command(forKeyCode: 111, modifiers: []) == .developerTools)
    #expect(
      ShaarDevToolsShortcut.command(forKeyCode: 111, modifiers: [.function]) == .developerTools)
  }

  @Test func directChromiumChordKeepsItsOwnCommand() {
    #expect(
      ShaarDevToolsShortcut.command(
        forKeyCode: 34, modifiers: [.command, .option, .shift]) == .chromiumDeveloperTools)
  }

  @Test func unrelatedKeysAndModifiedF12DoNotRoute() {
    #expect(ShaarDevToolsShortcut.command(forKeyCode: 110, modifiers: []) == nil)
    #expect(
      ShaarDevToolsShortcut.command(forKeyCode: 111, modifiers: [.command]) == nil)
    #expect(
      ShaarDevToolsShortcut.command(
        forKeyCode: 34, modifiers: [.command, .option]) == nil)
  }
}
