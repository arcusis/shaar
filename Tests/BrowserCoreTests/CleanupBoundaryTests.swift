// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func removingDormantFavoriteClearsEverySavedSelection() throws {
  var session = BrowserSession.fresh()
  let profile = session.selectedSpace.profileID
  let made = session.addFavorite(
    profileID: profile, originalURL: URL(string: "https://example.com")!, title: "Saved")
  let id = try #require(made)
  _ = session.addSpace(name: "Shared", sharingProfile: profile)
  session.favoritePages.removeAll { $0.favoriteID == id }
  for index in session.spaces.indices where session.spaces[index].profileID == profile {
    session.spaces[index].selectedFavoriteID = id
  }
  let removed = session.removeFavorite(id, disposition: .closePage)
  #expect(removed)
  #expect(session.spaces.allSatisfy { $0.selectedFavoriteID != id })
  #expect(!session.favorites.contains { $0.id == id })
}

@Test func snapshotReportsDirectoryFlushFailureAfterAtomicReplacement() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "snapshot-restricted-directory-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try? FileManager.default.removeItem(at: root)
  }
  let file = SnapshotFile<BrowserSession>(url: root.appending(path: "session.json"))
  let session = BrowserSession.fresh()
  // Owned directory permits writing/traversal, but neither listing nor read-only directory open.
  // This deterministically covers errors otherwise reached only by teardown racing a writer.
  try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)
  #expect(throws: (any Error).self) { try file.save(session) }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  #expect(try file.loadPrimary() == session)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["session.json"])
}
