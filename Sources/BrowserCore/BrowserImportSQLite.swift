// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CSQLite
import Foundation

enum BrowserImportSQLite {
  enum Value {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
  }

  static func rows(at source: URL, query: String, limit: Int = 100_000) throws -> [[String: Value]]
  {
    var rows: [[String: Value]] = []
    try read(at: source, queries: [query], limit: limit) { _, result in rows = result }
    return rows
  }

  static func read(
    at source: URL, queries: [String], limit: Int = 100_000,
    consume: (Int, [[String: Value]]) throws -> Void
  ) throws {
    guard !queries.isEmpty else { return }
    let temporary = FileManager.default.temporaryDirectory
      .appending(path: "shaar-import-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: URL(filePath: temporary.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(filePath: temporary.path + "-shm"))
    }

    var original: OpaquePointer?
    guard
      sqlite3_open_v2(source.path, &original, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let original
    else { throw BrowserImport.ImportError.databaseUnavailable("open source") }
    defer { sqlite3_close(original) }
    sqlite3_busy_timeout(original, 2_000)

    var copy: OpaquePointer?
    guard
      sqlite3_open_v2(
        temporary.path, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK, let destinationDatabase = copy
    else { throw BrowserImport.ImportError.databaseUnavailable("create snapshot") }
    defer {
      if let copy { sqlite3_close(copy) }
    }

    guard let backup = sqlite3_backup_init(destinationDatabase, "main", original, "main") else {
      throw BrowserImport.ImportError.databaseUnavailable("start snapshot")
    }
    let backupResult = sqlite3_backup_step(backup, -1)
    let backupFinished = sqlite3_backup_finish(backup)
    guard backupResult == SQLITE_DONE, backupFinished == SQLITE_OK else {
      throw BrowserImport.ImportError.databaseUnavailable("copy snapshot")
    }
    guard sqlite3_close(destinationDatabase) == SQLITE_OK else {
      throw BrowserImport.ImportError.databaseUnavailable("close snapshot")
    }
    copy = nil

    var snapshot: OpaquePointer?
    guard
      sqlite3_open_v2(temporary.path, &snapshot, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let snapshot
    else { throw BrowserImport.ImportError.databaseUnavailable("open copied snapshot") }
    defer { sqlite3_close(snapshot) }

    for (queryIndex, query) in queries.enumerated() {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(snapshot, query, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw BrowserImport.ImportError.databaseUnavailable("prepare query") }
      defer { sqlite3_finalize(statement) }

      let columnCount = Int(sqlite3_column_count(statement))
      let columnNames = (0..<columnCount).map { index -> String? in
        guard let name = sqlite3_column_name(statement, Int32(index)) else { return nil }
        return String(cString: name)
      }
      var result: [[String: Value]] = []
      var stepResult = sqlite3_step(statement)
      while stepResult == SQLITE_ROW {
        guard result.count < limit else { throw BrowserImport.ImportError.tooManyRows }
        var row: [String: Value] = [:]
        row.reserveCapacity(columnCount)
        for index in 0..<columnCount {
          guard let name = columnNames[index] else { continue }
          switch sqlite3_column_type(statement, Int32(index)) {
          case SQLITE_INTEGER:
            row[String(cString: name)] = .integer(sqlite3_column_int64(statement, Int32(index)))
          case SQLITE_FLOAT:
            row[String(cString: name)] = .real(sqlite3_column_double(statement, Int32(index)))
          case SQLITE_TEXT:
            if let value = sqlite3_column_text(statement, Int32(index)) {
              let bytes = Int(sqlite3_column_bytes(statement, Int32(index)))
              row[String(cString: name)] = .text(
                String(decoding: UnsafeBufferPointer(start: value, count: bytes), as: UTF8.self))
            } else {
              row[String(cString: name)] = .null
            }
          default:
            row[String(cString: name)] = .null
          }
        }
        result.append(row)
        stepResult = sqlite3_step(statement)
      }
      guard stepResult == SQLITE_DONE else {
        throw BrowserImport.ImportError.databaseUnavailable("read query")
      }
      try consume(queryIndex, result)
    }
  }
}
