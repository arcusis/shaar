// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct DeviceChooserSelectionAccessibilityTests {
  @Test func selectedTraitUsesThePresentedOptionRevision() {
    let option = DeviceChooserOption(optionID: "usb-device", title: "USB device", detail: "")
    let oldRevision = UUID()
    let newRevision = UUID()
    var selection = DeviceChooserSelection(options: [option], revision: oldRevision)
    selection.select("usb-device", from: [option], revision: oldRevision)

    #expect(
      DeviceChooserConsent.isOptionSelected(
        "usb-device", options: [option], selection: selection, revision: oldRevision))
    #expect(
      !DeviceChooserConsent.isOptionSelected(
        "usb-device", options: [option], selection: selection, revision: newRevision))
  }
}
