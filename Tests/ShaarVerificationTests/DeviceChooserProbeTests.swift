// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct DeviceChooserProbeTests {
  @Test func aMissingUsbChooserFailsTheHiddenProbe() {
    #expect(
      DeviceChooserProbePolicy.missingChooserError(transport: "usb")
        == "The WebUSB request settled without a native device chooser.")
  }

  @Test func otherTransportFallbacksAreUnaffected() {
    for transport in ["serial", "bluetooth", "hid"] {
      #expect(DeviceChooserProbePolicy.missingChooserError(transport: transport) == nil)
    }
  }
}
