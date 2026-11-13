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
    let externalRoot =
      FileManager.default.temporaryDirectory.appending(path: "OutsideDownloads-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalRoot)
    }
    let file = root.appending(path: "report.pdf")
    let link = root.appending(path: "linked-report.pdf")
    let externalFile = externalRoot.appending(path: "outside.pdf")
    let externalLink = root.appending(path: "external-report.pdf")
    try Data("report".utf8).write(to: file)
    try Data("outside".utf8).write(to: externalFile)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: externalFile)

    let direct = try #require(DownloadsFolderFile(url: file))
    let throughLink = try #require(DownloadsFolderFile(url: link))
    #expect(throughLink.url == file.resolvingSymlinksInPath().standardizedFileURL)
    #expect(throughLink.id == direct.id)

    let source = DownloadsFolderSource(directory: root)
    #expect(source.files.map(\.url).contains(file.resolvingSymlinksInPath().standardizedFileURL))
    #expect(source.files.map(\.url).contains(throughLink.url))
    #expect(
      !source.files.map(\.url).contains(externalFile.resolvingSymlinksInPath().standardizedFileURL))
    let profileID = UUID()
    let first = try #require(source.item(id: direct.id, profileID: profileID))
    source.refresh()
    let refreshed = try #require(source.item(id: direct.id, profileID: profileID))
    #expect(refreshed.id == first.id)
    #expect(refreshed.fileURL == file)
    #expect(refreshed.profileID == profileID)
  }
}
