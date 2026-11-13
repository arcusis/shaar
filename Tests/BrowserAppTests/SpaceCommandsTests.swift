// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Testing

@testable import ArcusisBrowser

struct SpaceCommandsTests {
  @Test func pageCommandsKeepSplitAndCopyURLShortcutsDistinct() {
    #expect(SpaceCommands.splitViewShortcut.key == "=")
    #expect(SpaceCommands.splitViewShortcut.modifiers == [.control, .shift])
    #expect(SpaceCommands.copyURLShortcut.key == "c")
    #expect(SpaceCommands.copyURLShortcut.modifiers == [.command, .shift])
  }
}
