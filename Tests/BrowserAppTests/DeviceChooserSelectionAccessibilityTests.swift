// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct DeviceChooserSelectionAccessibilityTests {
  @Test func selectedTraitUsesThePresentedOptionRevision() {
    let option = DeviceChooserOption(index: 0, title: "USB device", detail: "")
    let oldRevision = UUID()
    let newRevision = UUID()
    var selection = DeviceChooserSelection(options: [option], revision: oldRevision)
    selection.select(0, from: [option], revision: oldRevision)

    #expect(
      DeviceChooserConsent.isOptionSelected(
        0, options: [option], selection: selection, revision: oldRevision))
    #expect(
      !DeviceChooserConsent.isOptionSelected(
        0, options: [option], selection: selection, revision: newRevision))
  }
}
