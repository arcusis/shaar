// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Test func downloadedFolderBookmarkSurvivesAnUnrelatedPreferenceSave() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appending(path: "preferences.json")
  let profileID = UUID()
  let bookmark = Data([1, 2, 3, 4])
  let bookmarks = try String(
    decoding: JSONEncoder().encode([profileID: bookmark]), as: UTF8.self)
  let initial = """
    {"version":2,"sidebarInitiallyVisible":true,"profileSearchEngines":[],"profileDownloadBookmarks":\(bookmarks)}
    """
  try Data(initial.utf8).write(to: file)

  let preferences = BrowserPreferencesStore(fileURL: file)
  #expect(preferences.storageNotice == nil)
  preferences.setSidebarInitiallyVisible(false)

  let document = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  let savedBookmarks = try #require(document["profileDownloadBookmarks"])
  let savedData = try JSONSerialization.data(withJSONObject: savedBookmarks)
  let decoded = try JSONDecoder().decode([UUID: Data].self, from: savedData)
  #expect(decoded[profileID] == bookmark)
}
