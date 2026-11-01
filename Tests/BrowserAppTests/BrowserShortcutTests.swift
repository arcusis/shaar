// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Testing

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
