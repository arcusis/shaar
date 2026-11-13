// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct LibraryDownloadQueryTests {
  @Test func statusDistinguishesPausedDangerousAndTerminalDownloads() throws {
    #expect(
      LibraryDownloadQuery.status(try download(state: .downloading, paused: true))
        == PanelsL10n.string("Paused"))
    #expect(
      LibraryDownloadQuery.status(try download(state: .downloading, paused: false))
        == PanelsL10n.string("Downloading"))
    #expect(
      LibraryDownloadQuery.status(try download(state: .finished, dangerous: true))
        == PanelsL10n.string("Blocked"))
    #expect(
      LibraryDownloadQuery.status(try download(state: .finished))
        == PanelsL10n.string("Complete"))
    #expect(
      LibraryDownloadQuery.status(try download(state: .failed))
        == PanelsL10n.string("Interrupted"))
    #expect(
      LibraryDownloadQuery.status(try download(state: .cancelled))
        == PanelsL10n.string("Cancelled"))
  }

  private func download(
    state: DownloadState, paused: Bool = false, dangerous: Bool = false
  ) throws -> BrowserDownload {
    try #require(
      BrowserDownload(
        id: UUID().uuidString.lowercased(), profileID: UUID(), filename: "file.bin",
        path: "/tmp/file.bin", sourceURL: "https://download.example/file.bin", state: state,
        paused: paused, dangerous: dangerous, offTheRecord: false,
        received: 10, total: 10, startTime: 1_000))
  }
}
