// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadsModelTests {
  @Test func directoryChangeReplacesCachedProfileFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let original = root.appending(path: "original")
    let replacement = root.appending(path: "replacement")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("old".utf8).write(to: original.appending(path: "old.pdf"))
    try Data("new".utf8).write(to: replacement.appending(path: "new.pdf"))

    let profileID = UUID()
    var directory = original
    let model = DownloadsModel(profileDirectory: { _ in directory })

    #expect(model.libraryItems(in: profileID).map(\.filename) == ["old.pdf"])
    directory = replacement
    #expect(model.libraryItems(in: profileID).map(\.filename) == ["new.pdf"])
  }
}
