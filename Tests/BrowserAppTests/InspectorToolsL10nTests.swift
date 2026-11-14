// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

struct InspectorToolsL10nTests {
  @Test func cookieRejectionUsesHebrewCatalogText() {
    #expect(
      InspectorToolsL10n.backendError("Chromium rejected this cookie.", language: .hebrew)
        == "Chromium דחה את קובץ ה‑Cookie.")
  }

  @Test func backendErrorTranslatesOnlyKnownStorageMessages() {
    for message in [
      "Storage is not available in this document.",
      "Value exceeds the 256K-character editor limit.",
      "Storage could not be read.",
      "Storage key or value exceeds the editor limit.",
      "Storage could not be changed; it may be restricted or full.",
    ] {
      #expect(InspectorToolsL10n.backendError(message) == InspectorToolsL10n.string(message))
    }

    let unknown = "Database failed at /private/profile with code 17"
    #expect(InspectorToolsL10n.backendError(unknown) == unknown)
  }
}
