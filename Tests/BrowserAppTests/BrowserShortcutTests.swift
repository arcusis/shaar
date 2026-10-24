import AppKit
import ChromiumBridge
import Testing

@Test func browserShortcutsDoNotStealBitwardenAutofillOrOtherModifierVariants() {
  #expect(ARCReservedBrowserShortcut("l", .command))
  #expect(ARCReservedBrowserShortcut("t", .command))
  #expect(ARCReservedBrowserShortcut("r", [.command, .capsLock]))
  #expect(!ARCReservedBrowserShortcut("L", [.command, .shift]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .option]))
  #expect(!ARCReservedBrowserShortcut("l", [.command, .control]))
  #expect(!ARCReservedBrowserShortcut("l", []))
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
