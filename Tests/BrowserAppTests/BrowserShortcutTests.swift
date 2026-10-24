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
