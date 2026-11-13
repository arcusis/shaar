// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

struct InspectorContrastLineTests {
  @Test @MainActor func ratioTextUsesTwoDecimalPlaces() {
    #expect(InspectorContrastLine.ratioText(4.5) == "4.50:1")
    #expect(InspectorContrastLine.ratioText(2.999) == "3.00:1")
  }
}
