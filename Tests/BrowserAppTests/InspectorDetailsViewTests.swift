// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Testing

@testable import ArcusisBrowser

struct InspectorDetailsViewTests {
  @Test func selectedComponentRowExposesSelectedAccessibilityTrait() {
    #expect(InspectorComponentRowAccessibility.traits(isSelected: true).contains(.isSelected))
  }

  @Test func unselectedComponentRowDoesNotExposeSelectedAccessibilityTrait() {
    #expect(!InspectorComponentRowAccessibility.traits(isSelected: false).contains(.isSelected))
  }
}
