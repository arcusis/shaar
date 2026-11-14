// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct InspectorDetailsModelTests {
  @Test func rendererAccessibilityReplyCannotSupplyNativeTreeProperties() throws {
    let payload = Data(
      #"{"aria":[{"name":"aria-label","value":"Save"}],"tabOrder":2,"tabLimit":false,"warnings":[],"role":"button","name":"Spoofed","nameSource":"contents","ignored":true,"properties":[{"name":"focusable","value":"true"}]}"#.utf8)

    let decoded = try JSONDecoder().decode(InspectorAccessibilityData.self, from: payload)

    #expect(decoded.aria.map(\.name) == ["aria-label"])
    #expect(decoded.tabOrder == 2)
    #expect(decoded.role == "Unavailable")
    #expect(decoded.name.isEmpty)
    #expect(decoded.nameSource == nil)
    #expect(decoded.ignored == nil)
    #expect(decoded.properties.isEmpty)
  }
}
