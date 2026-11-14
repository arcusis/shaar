// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

@MainActor
struct PrintDocumentTitleTests {
  @Test func usesPageTitleForDefaultPDFName() {
    #expect(
      PrintDocumentTitle.make(pageTitle: "  Quarterly report  ", productName: "Shaar")
        == "Quarterly report")
  }

  @Test func fallsBackAndRemovesControlCharacters() {
    #expect(PrintDocumentTitle.make(pageTitle: "\n\t", productName: "Shaar") == "Shaar")
    #expect(
      PrintDocumentTitle.make(pageTitle: "First\nSecond", productName: "Shaar") == "First Second")
    #expect(
      PrintDocumentTitle.make(pageTitle: " First \n\t Second ", productName: "Shaar")
        == "First Second")
    #expect(
      PrintDocumentTitle.make(pageTitle: "First\u{2028}Second", productName: "Shaar")
        == "First Second")
    #expect(
      PrintDocumentTitle.make(pageTitle: "First\u{2029}Second", productName: "Shaar")
        == "First Second")
  }

  @Test func capsPageTitleLength() {
    let result = PrintDocumentTitle.make(
      pageTitle: String(repeating: "a", count: 200), productName: "Shaar")
    #expect(result.count == 120)
  }

  @Test func removesBidiFormattingAndFilenameSeparators() {
    #expect(
      PrintDocumentTitle.make(pageTitle: "Report\u{202E}fdp/part", productName: "Shaar")
        == "Report fdp part")
  }

  @Test func updatesTheAttachedWindowTitleWithoutShowingAWindow() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless, backing: .buffered, defer: false)
    let view = PrintDocumentTitleView(pageTitle: "First page")
    try #require(window.contentView).addSubview(view)
    #expect(window.title == "First page")

    view.setPageTitle("Second page")
    #expect(window.title == "Second page")
  }
}
