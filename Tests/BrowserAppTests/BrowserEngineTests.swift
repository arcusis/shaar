// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineDownloadActionsTests {
  @Test func openActionOpensOnlyTheRequestedURL() {
    let file = URL(filePath: "/tmp/download.pdf")
    var opened: [URL] = []
    var revealed: [URL] = []

    let succeeded = BrowserEngine.performDownloadFileAction(
      file, open: true,
      openFile: { opened.append($0); return true },
      revealFile: { revealed.append($0) })

    #expect(succeeded)
    #expect(opened == [file])
    #expect(revealed.isEmpty)
  }

  @Test func showInFinderRevealsOnlyTheRequestedURL() {
    let file = URL(filePath: "/tmp/download.pdf")
    var opened: [URL] = []
    var revealed: [URL] = []

    let succeeded = BrowserEngine.performDownloadFileAction(
      file, open: false,
      openFile: { opened.append($0); return true },
      revealFile: { revealed.append($0) })

    #expect(succeeded)
    #expect(opened.isEmpty)
    #expect(revealed == [file])
  }

  @Test func openFailureIsReportedToTheCaller() {
    let file = URL(filePath: "/tmp/download.pdf")
    var revealed: [URL] = []

    let succeeded = BrowserEngine.performDownloadFileAction(
      file, open: true,
      openFile: { _ in false },
      revealFile: { revealed.append($0) })

    #expect(!succeeded)
    #expect(revealed.isEmpty)
  }
}
