// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct LibraryDownloadsViewTests {
  @Test func openSendsOnlyTheSelectedDownloadToWorkspace() {
    let file = URL(filePath: "/tmp/library-download.pdf")
    var opened: [URL] = []
    var revealed: [URL] = []

    LibraryDownloadsView.performDownloadFileAction(
      file, inFinder: false,
      openFile: { opened.append($0) }, revealFile: { revealed.append($0) })

    #expect(opened == [file])
    #expect(revealed.isEmpty)
  }

  @Test func showInFinderRevealsOnlyTheSelectedDownload() {
    let file = URL(filePath: "/tmp/library-download.pdf")
    var opened: [URL] = []
    var revealed: [URL] = []

    LibraryDownloadsView.performDownloadFileAction(
      file, inFinder: true,
      openFile: { opened.append($0) }, revealFile: { revealed.append($0) })

    #expect(opened.isEmpty)
    #expect(revealed == [file])
  }
}
