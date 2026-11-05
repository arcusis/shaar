// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridgeVerification
import Testing

@Suite("Shaar native selection audit")
struct NativeSelectionAuditTests {
  @Test @MainActor func reportsOnlyThePageAttachedToItsOwningHiddenWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [],
      backing: .buffered, defer: false)
    let host = NSView(frame: window.contentView!.bounds)
    window.contentView = host
    let tab = NSView(frame: host.bounds)

    let detached = ARCProbeNormalSelectionAudit(tab, host, window)
    #expect(detached["supported"] as? Bool == true)
    #expect(detached["liveTab"] as? Bool == true)
    #expect(detached["selectedNativeTab"] as? Bool == false)
    #expect(detached["displayedNativeWebContents"] as? Bool == false)

    host.addSubview(tab)
    let selected = ARCProbeNormalSelectionAudit(tab, host, window)
    #expect(selected["selectedNativeTab"] as? Bool == true)
    #expect(selected["displayedNativeWebContents"] as? Bool == true)

    let content = NSView(frame: host.bounds)
    host.addSubview(content)
    content.addSubview(tab)
    let nested = ARCProbeNormalSelectionAudit(tab, host, window)
    #expect(nested["selectedNativeTab"] as? Bool == true)
    #expect(nested["displayedNativeWebContents"] as? Bool == true)

    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [],
      backing: .buffered, defer: false)
    let foreign = ARCProbeNormalSelectionAudit(tab, host, other)
    #expect(foreign["selectedNativeTab"] as? Bool == false)
    #expect(foreign["displayedNativeWebContents"] as? Bool == false)
  }
}
