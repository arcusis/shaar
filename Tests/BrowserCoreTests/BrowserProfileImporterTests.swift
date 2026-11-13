// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CSQLite
import Foundation
import Testing

@testable import BrowserCore

@Test func firefoxProfileImportSnapshotBenchmark() throws {
  let database = try databaseURLProfile(name: "FirefoxSnapshot", databaseName: "places.sqlite")
  defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
  try createDatabase(
    sqlFixture: "FirefoxPlaces.sql", at: database,
    extraSQL: """
      CREATE TABLE snapshot_padding(data BLOB);
      INSERT INTO snapshot_padding VALUES(zeroblob(16000000));
      """
  )

  let start = ContinuousClock.now
  var importedItems = 0
  for _ in 0..<3 {
    importedItems += try BrowserImport.readProfile(at: database, source: .firefox).items.count
  }
  print("firefoxProfileImportSnapshotBenchmark: \(start.duration(to: .now))")
  #expect(importedItems == 12)
}

@Test func chromiumFamilyProfilesImportBookmarksAndHistoryWithSourceAttribution() throws {
  for source in [BrowserImportSource.chrome, .edge, .brave, .arc] {
    let profile = try profileDirectory(name: source.rawValue)
    try copyFixture("ChromiumBookmarks", to: profile.appending(path: "Bookmarks"))
    try createDatabase(
      sqlFixture: "ChromiumHistory.sql", at: profile.appending(path: "History"))
    let originalHistory = try Data(contentsOf: profile.appending(path: "History"))

    let batch = try BrowserImport.readProfile(at: profile, source: source)
    #expect(batch.source == source)
    #expect(batch.bookmarks.count == 1 && batch.bookmarks[0].source == source)
    #expect(batch.bookmarks[0].folder == "Work")
    #expect(batch.history.count == 1 && batch.history[0].source == source)
    #expect(batch.history[0].visitTimes.count == 2)
    #expect(batch.history[0].visitTimes.last == Date(timeIntervalSince1970: 1_700_000_002))
    #expect(try Data(contentsOf: profile.appending(path: "History")) == originalHistory)

    let rows = BrowserImport.historyRows(for: batch.history)
    #expect(rows.count == 1)
    #expect(rows[0]["s"] as? String == source.rawValue)
    #expect((rows[0]["v"] as? [Double])?.count == 2)
    #expect(rows[0]["n"] as? Int == 2)
  }
}

@Test func historyImportPreviewUsesHostForMissingTitles() throws {
  let profile = try profileDirectory(name: "ChromeUntitledHistory")
  try copyFixture("ChromiumBookmarks", to: profile.appending(path: "Bookmarks"))
  try createDatabase(
    sqlFixture: "ChromiumHistory.sql", at: profile.appending(path: "History"),
    extraSQL: """
      INSERT INTO urls VALUES(2, 'https://untitled.example.test/path', NULL, 1, 13344473603000000);
      INSERT INTO visits VALUES(4, 2, 13344473603000000, 0);
      INSERT INTO urls VALUES(3, 'https://spaces.example.test/path', '   ', 1, 13344473604000000);
      INSERT INTO visits VALUES(5, 3, 13344473604000000, 0);
      INSERT INTO urls VALUES(4, 'https://history.example.test/', '   ', 1, 13344473605000000);
      INSERT INTO visits VALUES(6, 4, 13344473605000000, 0);
      """)

  let batch = try BrowserImport.readProfile(at: profile, source: .chrome)
  #expect(
    batch.history.map(\.title)
      == ["History page", "untitled.example.test", "spaces.example.test"])
}

@Test func chromiumProfileImportsAvailableDataWithoutTheOtherFile() throws {
  let profile = try profileDirectory(name: "ChromeBookmarksOnly")
  try copyFixture("ChromiumBookmarks", to: profile.appending(path: "Bookmarks"))

  let batch = try BrowserImport.readProfile(at: profile, source: .chrome)
  #expect(batch.bookmarks.map(\.address) == ["https://work.example.test/"])
  #expect(batch.history.isEmpty)

  let historyProfile = try profileDirectory(name: "ChromeHistoryOnly")
  try createDatabase(
    sqlFixture: "ChromiumHistory.sql", at: historyProfile.appending(path: "History"))
  let historyBatch = try BrowserImport.readProfile(at: historyProfile, source: .chrome)
  #expect(historyBatch.bookmarks.isEmpty)
  #expect(historyBatch.history.map(\.address) == ["https://history.example.test/"])
}

@Test func safariProfileImportsItsBookmarkPlistAndSafariEpochHistory() throws {
  let profile = try profileDirectory(name: "Safari")
  try copyFixture("SafariBookmarks.plist", to: profile.appending(path: "Bookmarks.plist"))
  try createDatabase(sqlFixture: "SafariHistory.sql", at: profile.appending(path: "History.db"))

  let batch = try BrowserImport.readProfile(at: profile, source: .safari)
  #expect(batch.bookmarks.map(\.address) == ["https://safari.example.test/"])
  #expect(batch.bookmarks[0].folder == "Reading")
  #expect(batch.history.map(\.address) == ["https://safari-history.example.test/"])
  #expect(batch.history[0].visitTimes == [Date(timeIntervalSince1970: 1_678_307_200)])
  #expect(batch.items.allSatisfy { $0.source == .safari })
}

@Test func safariProfileImportsAvailableDataWithoutTheOtherFile() throws {
  let bookmarksProfile = try profileDirectory(name: "SafariBookmarksOnly")
  try copyFixture("SafariBookmarks.plist", to: bookmarksProfile.appending(path: "Bookmarks.plist"))
  let bookmarkBatch = try BrowserImport.readProfile(at: bookmarksProfile, source: .safari)
  #expect(bookmarkBatch.bookmarks.map(\.address) == ["https://safari.example.test/"])
  #expect(bookmarkBatch.history.isEmpty)

  let historyProfile = try profileDirectory(name: "SafariHistoryOnly")
  try createDatabase(
    sqlFixture: "SafariHistory.sql", at: historyProfile.appending(path: "History.db"))
  let historyBatch = try BrowserImport.readProfile(at: historyProfile, source: .safari)
  #expect(historyBatch.bookmarks.isEmpty)
  #expect(historyBatch.history.map(\.address) == ["https://safari-history.example.test/"])
}

@Test func firefoxPlacesImportsBookmarkFoldersAndUnixMicrosecondVisits() throws {
  let profile = try databaseURLProfile(name: "Firefox", databaseName: "places.sqlite")
  try createDatabase(sqlFixture: "FirefoxPlaces.sql", at: profile)

  let batch = try BrowserImport.readProfile(at: profile, source: .firefox)
  #expect(batch.bookmarks.count == 3)
  #expect(batch.bookmarks[0].folder == nil)
  #expect(batch.bookmarks[0].address == "https://firefox-bookmark.example.test/")
  #expect(batch.bookmarks[1].folder == "Research")
  #expect(batch.bookmarks[1].address == "https://firefox-bookmark.example.test/")
  #expect(batch.bookmarks[2].title == "Untitled")
  #expect(batch.history.count == 1)
  #expect(batch.history[0].visitTimes.count == 2)
  #expect(batch.history[0].visitTimes.last == Date(timeIntervalSince1970: 1_700_000_000.2))
  #expect(batch.items.allSatisfy { $0.source == .firefox })
}

@Test func firefoxImportKeepsNestedFoldersNamedLikeRootFolders() throws {
  let database = try databaseURLProfile(name: "Firefox", databaseName: "places.sqlite")
  try createDatabase(
    sqlFixture: "FirefoxPlaces.sql", at: database,
    extraSQL: """
      INSERT INTO moz_bookmarks VALUES(8, 2, NULL, 4, 2, 'toolbar');
      INSERT INTO moz_bookmarks VALUES(9, 1, 2, 8, 0, 'Nested toolbar bookmark');
      """
  )

  let batch = try BrowserImport.readProfile(at: database, source: .firefox)
  let bookmark = try #require(batch.bookmarks.first { $0.title == "Nested toolbar bookmark" })
  #expect(bookmark.folderComponents == ["Research", "toolbar"])
}

@Test func firefoxImportOmitsRootFoldersWithLocalizedTitles() throws {
  let database = try databaseURLProfile(name: "Firefox", databaseName: "places.sqlite")
  try createDatabase(
    sqlFixture: "FirefoxPlaces.sql", at: database,
    extraSQL: """
      UPDATE moz_bookmarks SET title = 'Wurzel' WHERE id = 1;
      UPDATE moz_bookmarks SET title = 'Lesezeichenleiste' WHERE id = 2;
      """)

  let batch = try BrowserImport.readProfile(at: database, source: .firefox)
  let bookmark = try #require(batch.bookmarks.first { $0.title == "Firefox bookmark" })
  #expect(bookmark.folderComponents == nil)
}

@Test func privateBrowserProfileDirectoriesAreRejectedBeforeReading() throws {
  for name in ["Incognito", "InPrivate", "Guest Profile", "Guest Profile 2", "Private Browsing"] {
    let profile = try profileDirectory(name: name)
    #expect(throws: BrowserImport.ImportError.self) {
      try BrowserImport.readProfile(at: profile, source: .chrome)
    }
  }
  #expect(BrowserImport.ImportError.privateProfile.errorDescription?.contains("Private") == true)
}

@Test func ordinaryProfileFolderContainingGuestImportsNormally() throws {
  let profile = try profileDirectory(name: "Guesthouse")
  try copyFixture("ChromiumBookmarks", to: profile.appending(path: "Bookmarks"))
  try createDatabase(sqlFixture: "ChromiumHistory.sql", at: profile.appending(path: "History"))

  let batch = try BrowserImport.readProfile(at: profile, source: .chrome)

  #expect(batch.bookmarks.count == 1)
  #expect(batch.history.count == 1)
}

@Test func browserImportAttributesBookmarkExportsAndReportsImporterErrors() throws {
  #expect(BrowserImportSource.chrome.id == "chrome")
  #expect(BrowserImportSource.firefox.title == "Firefox")
  let export = FileManager.default.temporaryDirectory.appending(path: "Bookmarks-\(UUID()).json")
  try copyFixture("ChromiumBookmarks", to: export)
  let batch = try BrowserImport.read(export, source: .edge)
  #expect(batch.source == .edge)
  #expect(batch.bookmarks.count == 1 && batch.bookmarks[0].source == .edge)

  #expect(BrowserImport.ImportError.databaseUnavailable("fixture").errorDescription != nil)
  #expect(BrowserImport.ImportError.tooManyRows.errorDescription?.contains("at once") == true)
}

@Test func sqliteSnapshotDecodesTypedColumnsAndEnforcesTheRowLimit() throws {
  let profile = try profileDirectory(name: "SQLite")
  let database = profile.appending(path: "History")
  try createDatabase(sqlFixture: "ChromiumHistory.sql", at: database)
  let rows = try BrowserImportSQLite.rows(
    at: database,
    query: "SELECT 7 AS integer_value, 2.5 AS real_value, 'text' AS text_value, NULL AS null_value"
  )
  #expect(rows.count == 1)
  if case .integer(7) = rows[0]["integer_value"] {
  } else {
    Issue.record("Integer column was lost.")
  }
  if case .real(2.5) = rows[0]["real_value"] {} else { Issue.record("Real column was lost.") }
  if case .text("text") = rows[0]["text_value"] {} else { Issue.record("Text column was lost.") }
  if case .null = rows[0]["null_value"] {} else { Issue.record("Null column was lost.") }

  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImportSQLite.rows(
      at: database, query: "SELECT 1 UNION ALL SELECT 2", limit: 1)
  }
}

@Test func sqliteSnapshotPreservesTextAfterEmbeddedNUL() throws {
  let profile = try profileDirectory(name: "SQLiteNUL")
  let database = profile.appending(path: "History")
  try createDatabase(sqlFixture: "ChromiumHistory.sql", at: database)

  let rows = try BrowserImportSQLite.rows(
    at: database, query: "SELECT CAST(x'4162004364' AS TEXT) AS title")
  guard case .text(let title) = rows.first?["title"] else {
    Issue.record("SQLite TEXT was not decoded.")
    return
  }
  #expect(title == "Ab\0Cd")
}

@Test func repeatedHistoryVisitGroupingFocusedBenchmark() throws {
  let profile = try profileDirectory(name: "HistoryGroupingBenchmark")
  try createDatabase(
    sqlFixture: "ChromiumHistory.sql", at: profile.appending(path: "History"),
    extraSQL: """
      WITH RECURSIVE sequence(value) AS (
        SELECT 4 UNION ALL SELECT value + 1 FROM sequence WHERE value < 30003
      )
      INSERT INTO visits SELECT value, 1, 13344473602000000 + value, 0 FROM sequence;
      """)

  let start = ContinuousClock.now
  let batch = try BrowserImport.readProfile(at: profile, source: .chrome)
  print("repeatedHistoryVisitGroupingFocusedBenchmark: \(start.duration(to: .now))")
  #expect(batch.history.count == 1)
  #expect(batch.history[0].visitTimes.count == 30_002)
}

@Test func sqliteSnapshotRejectsMissingSourcesAndInvalidQueries() throws {
  let absent = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).sqlite")
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImportSQLite.rows(at: absent, query: "SELECT 1")
  }

  let profile = try profileDirectory(name: "SQLiteQuery")
  let database = profile.appending(path: "History")
  try createDatabase(sqlFixture: "ChromiumHistory.sql", at: database)
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImportSQLite.rows(at: database, query: "SELECT FROM")
  }
}

@Test func sqliteSnapshotReturnsNoRowsForEmptyResult() throws {
  let profile = try profileDirectory(name: "SQLiteEmptyResult")
  let database = profile.appending(path: "History")
  try createDatabase(sqlFixture: "ChromiumHistory.sql", at: database)

  #expect(try BrowserImportSQLite.rows(at: database, query: "SELECT 1 WHERE 0").isEmpty)
}

@Test func profileImportersRejectMissingOrMalformedProfileFiles() throws {
  let regularFile = FileManager.default.temporaryDirectory.appending(path: "Chrome-\(UUID())")
  try Data("not a profile".utf8).write(to: regularFile)
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImport.readProfile(at: regularFile, source: .chrome)
  }

  let chromiumProfile = try profileDirectory(name: "ChromeEmpty")
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImport.readProfile(at: chromiumProfile, source: .chrome)
  }

  let safariDirectory = try profileDirectory(name: "SafariHistoryFile")
  try copyFixture("SafariBookmarks.plist", to: safariDirectory.appending(path: "Bookmarks.plist"))
  let safariHistory = safariDirectory.appending(path: "History.db")
  try createDatabase(sqlFixture: "SafariHistory.sql", at: safariHistory)
  #expect(try BrowserImport.readProfile(at: safariHistory, source: .safari).history.count == 1)

  let incompleteSafari = try profileDirectory(name: "SafariIncomplete")
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImport.readProfile(at: incompleteSafari, source: .safari)
  }

  let incompleteFirefox = try profileDirectory(name: "FirefoxIncomplete")
  #expect(throws: BrowserImport.ImportError.self) {
    try BrowserImport.readProfile(at: incompleteFirefox, source: .firefox)
  }
}

private func profileDirectory(name: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: "BrowserImport-\(UUID())")
  let profile = root.appending(path: name)
  try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
  return profile
}

private func databaseURLProfile(name: String, databaseName: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: "BrowserImport-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appending(path: databaseName)
}

private func copyFixture(_ name: String, to destination: URL) throws {
  let source = try #require(Bundle.module.resourceURL?.appending(path: "BrowserImport/\(name)"))
  try FileManager.default.copyItem(at: source, to: destination)
}

private func createDatabase(sqlFixture: String, at destination: URL, extraSQL: String = "") throws {
  let source = try #require(
    Bundle.module.resourceURL?.appending(path: "BrowserImport/\(sqlFixture)"))
  let sql = try String(contentsOf: source, encoding: .utf8) + "\n" + extraSQL
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      destination.path, &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil) == SQLITE_OK, let database
  else { throw BrowserImport.ImportError.databaseUnavailable("fixture setup") }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw BrowserImport.ImportError.databaseUnavailable("fixture setup")
  }
}
