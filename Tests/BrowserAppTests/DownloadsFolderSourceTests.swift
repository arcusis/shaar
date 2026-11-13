// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadsFolderSourceTests {
  @Test func refreshKeepsStableFileIdentityAndResolvesSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "report.pdf")
    let link = root.appending(path: "linked-report.pdf")
    try Data("report".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let direct = try #require(DownloadsFolderFile(url: file))
    let throughLink = try #require(DownloadsFolderFile(url: link))
    #expect(throughLink.url == file.resolvingSymlinksInPath().standardizedFileURL)
    #expect(throughLink.id == direct.id)

    let source = DownloadsFolderSource(directory: root)
    let profileID = UUID()
    let first = try #require(source.item(id: direct.id, profileID: profileID))
    source.refresh()
    let refreshed = try #require(source.item(id: direct.id, profileID: profileID))
    #expect(refreshed.id == first.id)
    #expect(refreshed.fileURL == file)
    #expect(refreshed.profileID == profileID)
  }
}
