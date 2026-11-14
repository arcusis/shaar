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

  @Test func downloadRecordsRejectBooleansInNumericFields() throws {
    let valid: [String: Any] = [
      "id": "8ce51349-a188-4bad-bd1c-011b48e48ca6",
      "filename": "file.txt",
      "path": "/tmp/file.txt",
      "url": "https://example.test/file",
      "state": "downloading",
      "paused": false,
      "dangerous": false,
      "offTheRecord": false,
      "received": 10.0,
      "total": 20.0,
      "startTime": 1.0,
    ]

    for field in ["received", "total", "startTime"] {
      let record = try json(valid.merging([field: true]) { _, new in new })
      let model = DownloadsModel()
      let profileID = UUID()
      model.changed(record, profileID: profileID)
      #expect(model.items(in: profileID).isEmpty, "Accepted boolean for \(field)")
    }
  }

  private func json(_ value: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
