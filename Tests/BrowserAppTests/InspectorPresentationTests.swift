// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorPresentationTests {
  @Test func startsWithExpectedSectionAndMenuState() {
    let presentation = InspectorPresentation()

    #expect(presentation.collapsedSections == ["Code:Layout", "Code:Element overrides", "Code:Tools"])
    #expect(presentation.codeSections == ["Code:Styles"])
    #expect(!presentation.copyMenuOpen)
    #expect(presentation.toast == nil)
  }

  @Test func replacingCopyToastCancelsEarlierTimeout() async throws {
    let presentation = InspectorPresentation()
    presentation.copied("CSS selector")
    try await Task.sleep(for: .seconds(1.5))

    presentation.copied("XPath")
    try await Task.sleep(for: .seconds(1.2))

    #expect(presentation.toast == "Copied XPath to clipboard")
    presentation.dismiss()
  }
}
