// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

struct PrintDocumentTitleTests {
  @Test func usesPageTitleForDefaultPDFName() {
    #expect(PrintDocumentTitle.make(pageTitle: "  Quarterly report  ", productName: "Shaar") == "Quarterly report")
  }

  @Test func fallsBackAndRemovesControlCharacters() {
    #expect(PrintDocumentTitle.make(pageTitle: "\n\t", productName: "Shaar") == "Shaar")
    #expect(PrintDocumentTitle.make(pageTitle: "First\nSecond", productName: "Shaar") == "First Second")
  }

  @Test func capsPageTitleLength() {
    let result = PrintDocumentTitle.make(pageTitle: String(repeating: "a", count: 200), productName: "Shaar")
    #expect(result.count == 120)
  }
}
