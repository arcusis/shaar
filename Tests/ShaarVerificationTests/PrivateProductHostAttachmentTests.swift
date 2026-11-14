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
    container.addSubview(hostingView)

    #expect(PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: container))

    hostingView.removeFromSuperview()
    #expect(!PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: container))
    #expect(!PrivateProductHostProbe.hostingViewIsAttached(hostingView, to: nil))
  }
}
