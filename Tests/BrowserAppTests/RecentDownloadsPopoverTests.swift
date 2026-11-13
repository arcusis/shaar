// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct RecentDownloadsPopoverTests {
  @Test func presentationShowsFiveNewestFirstAtTheFooter() throws {
    let profile = UUID()
    let downloads = try (1...6).map { index in
      try #require(
        BrowserDownload(
          id: UUID().uuidString, profileID: profile, filename: "item-\(index).txt",
          path: "/tmp/item-\(index).txt", sourceURL: "https://example.com/item-\(index)",
          state: .finished, paused: false, dangerous: false, offTheRecord: false,
          received: 1, total: 1, startTime: Double(index)))
    }

    #expect(RecentDownloadsPopover.presentedItems(downloads).map(\.filename) == [
      "item-5.txt", "item-4.txt", "item-3.txt", "item-2.txt", "item-1.txt",
    ])
  }
}
