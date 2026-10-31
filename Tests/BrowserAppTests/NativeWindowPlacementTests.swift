// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Testing

@testable import ArcusisBrowser

@Test func restoredWindowGeometryClampsToAvailableScreensAndMinimumSize() {
  let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
  let frame = NativeWindowPlacement.frame(
    saved: WorkspaceWindowGeometry(x: 9000, y: -9000, width: 3000, height: 2000),
    source: nil, screens: [screen])
  #expect(screen.contains(frame))
  #expect(frame.width == 1600 && frame.height == 1000)
  let cascaded = NativeWindowPlacement.frame(
    saved: nil, source: NSRect(x: 100, y: 100, width: 900, height: 650), screens: [screen])
  #expect(cascaded == NSRect(x: 122, y: 78, width: 900, height: 650))
}
