// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

struct InspectorDetailsL10nTests {
  @Test func authoredFailuresTranslateAndUnknownRendererTextStaysUntouched() {
    #expect(
      InspectorDetailsL10n.display(
        "The selected element is no longer available.", language: .hebrew)
        == "האלמנט שנבחר כבר אינו זמין.")
    #expect(
      InspectorDetailsL10n.display(
        "The page could not complete the Inspector request.", language: .hebrew)
        == "הדף לא הצליח להשלים את הבקשה מכלי הבדיקה.")
    let rendererMessage = "TypeError: page-defined failure"
    #expect(InspectorDetailsL10n.display(rendererMessage, language: .hebrew) == rendererMessage)
  }

  @Test func inspectorForwardChevronMirrorsInRightToLeftLayout() {
    #expect(InspectorL10n.forwardChevron(isRightToLeft: false) == "chevron.right")
    #expect(InspectorL10n.forwardChevron(isRightToLeft: true) == "chevron.left")
  }

  @Test func ltrTextIsIsolatedFromSurroundingRightToLeftCopy() {
    let value = "https://example.test/path?q=שלום"
    #expect(InspectorDetailsL10n.ltr(value) == "\u{2066}\(value)\u{2069}")
  }
}
