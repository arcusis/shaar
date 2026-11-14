// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ShaarVerification

@Suite @MainActor struct PrivateProductHostAttachmentTests {
  @Test func privateHostingViewMustRemainInItsNativeContainer() {
    let container = NSView()
    let hostingView = NSView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = container
    container.addSubview(hostingView)

    #expect(PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: container, in: window))

    window.contentView = NSView()
    #expect(!PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: container, in: window))

    hostingView.removeFromSuperview()
    window.contentView = container
    #expect(!PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: container, in: window))
    #expect(!PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: nil, in: window))
  }
}
