// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func downloadMetadataBoundsPathsNumbersAndPrivateRecords() throws {
  func item(
    path: String = "/tmp/report.pdf",
    source: String = "https://files.example.com/report?secret=token",
    privateItem: Bool = false, received: Double = 12, total: Double = 20,
    state: DownloadState = .finished, dangerous: Bool = false
  ) -> BrowserDownload? {
    BrowserDownload(
      id: "9b948ba6-d386-4e34-acdf-b2fb92fdb34b", profileID: UUID(), filename: "report.pdf",
      path: path, sourceURL: source, state: state, paused: false,
      dangerous: dangerous, offTheRecord: privateItem, received: received, total: total,
      startTime: 1)
  }
  let safe = try #require(item())
  #expect(safe.source == "files.example.com")
  #expect(safe.canOpen)
  #expect(safe.progress == 0.6)
  #expect(item(privateItem: true) == nil)
  #expect(item(path: "relative/file") == nil)
  #expect(item(path: "/tmp/bad\0path") == nil)
  #expect(item(received: .infinity) == nil)
  #expect(item(received: -1) == nil)
  #expect(item(received: Double(Int64.max)) == nil)
  #expect(item(total: -2) == nil)
  #expect(item(total: .nan) == nil)
  #expect(item(total: -1)?.totalBytes == nil)
  #expect(item(received: 30)?.progress == 1)
  #expect(item(path: "")?.canOpen == false)
  #expect(item(state: .downloading)?.canOpen == false)
  #expect(item(source: "blob:https://docs.example.com/id")?.source == "docs.example.com")
  #expect(item(source: "data:text/plain,secret")?.source == "Generated file")
  #expect(item(dangerous: true)?.canOpen == false)
  #expect(item(state: .downloading, dangerous: true)?.actions == [.cancel])
  #expect(item(dangerous: true)?.actions == [.remove])
}

@Test func downloadSourcesNameTheOriginWithoutExposingTheAddress() {
  func source(_ address: String) -> String? {
    BrowserDownload(
      id: "9b948ba6-d386-4e34-acdf-b2fb92fdb34b", profileID: UUID(), filename: "",
      path: "/tmp/file", sourceURL: address, state: .finished, paused: false,
      dangerous: false, offTheRecord: false, received: 1, total: 1, startTime: 0)?.source
  }
  #expect(source("chrome-extension://abcdefghijklmnopabcdefghijklmnop/file") == "Extension")
  #expect(source("ftp://files.example.com/file") == "Download")
  #expect(source("not a url") == "Download")
  #expect(source("https://" + String(repeating: "a", count: 8200) + ".example") == "Download")
}

@Test func downloadActionsFollowStateAndPause() {
  func actions(_ state: DownloadState, paused: Bool = false) -> [DownloadAction]? {
    BrowserDownload(
      id: "9b948ba6-d386-4e34-acdf-b2fb92fdb34b", profileID: UUID(), filename: "file",
      path: "/tmp/file", sourceURL: "https://example.com", state: state, paused: paused,
      dangerous: false, offTheRecord: false, received: 0, total: 0, startTime: 0)?.actions
  }
  #expect(actions(.downloading) == [.pause, .cancel])
  #expect(actions(.downloading, paused: true) == [.resume, .cancel])
  #expect(actions(.failed) == [.resume, .remove])
  #expect(actions(.cancelled) == [.remove])
  #expect(actions(.finished) == [.remove])
}

@Test func downloadsWithoutNameOrTotalUseSafeDefaults() throws {
  let item = try #require(
    BrowserDownload(
      id: "9b948ba6-d386-4e34-acdf-b2fb92fdb34b", profileID: UUID(), filename: "", path: "",
      sourceURL: "https://example.com", state: .downloading, paused: false, dangerous: false,
      offTheRecord: false, received: 5, total: 0, startTime: 0))
  #expect(item.filename == "Download")
  #expect(item.fileURL == nil)
  #expect(item.progress == nil)
  #expect(
    BrowserDownload(
      id: "not-a-uuid", profileID: UUID(), filename: "file", path: "/tmp/file",
      sourceURL: "https://example.com", state: .finished, paused: false, dangerous: false,
      offTheRecord: false, received: 0, total: 0, startTime: 0) == nil)
}
