// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum BrowserImportSource: String, CaseIterable, Identifiable, Sendable {
  case chrome, edge, brave, arc, safari, firefox

  public var id: String { rawValue }
  public var title: String { rawValue.capitalized }
}

public struct BrowserImportBatch: Equatable, Sendable {
  public let source: BrowserImportSource
  public let items: [BrowserImportItem]
  public init(source: BrowserImportSource, items: [BrowserImportItem]) {
    self.source = source
    self.items = items
  }
  public var bookmarks: [BrowserImportItem] { items.filter { $0.kind == .bookmark } }
  public var history: [BrowserImportItem] { items.filter { $0.kind == .history } }
}

public protocol BrowserProfileImporter: Sendable {
  var source: BrowserImportSource { get }
  func read(profileAt url: URL) throws -> BrowserImportBatch
}

enum BrowserProfileImporters {
  static func importer(for source: BrowserImportSource) -> any BrowserProfileImporter {
    switch source {
    case .chrome, .edge, .brave, .arc:
      ChromiumProfileImporter(source: source)
    case .safari:
      SafariProfileImporter()
    case .firefox:
      FirefoxProfileImporter()
    }
  }
}

private struct ChromiumProfileImporter: BrowserProfileImporter {
  let source: BrowserImportSource

  func read(profileAt url: URL) throws -> BrowserImportBatch {
    try rejectPrivateProfile(url)
    let isDirectory =
      url.hasDirectoryPath
      || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    guard isDirectory else { throw BrowserImport.ImportError.unsupported }
    let bookmarksURL = url.appending(path: "Bookmarks")
    let historyURL = url.appending(path: "History")
    guard FileManager.default.fileExists(atPath: bookmarksURL.path),
      FileManager.default.fileExists(atPath: historyURL.path)
    else { throw BrowserImport.ImportError.unsupported }
    let bookmarkItems = try BrowserImport.read(bookmarksURL).map { $0.with(source: source) }
    let historyItems = try ChromiumHistoryReader.read(historyURL, source: source)
    return BrowserImportBatch(source: source, items: bookmarkItems + historyItems)
  }
}

private struct SafariProfileImporter: BrowserProfileImporter {
  let source = BrowserImportSource.safari

  func read(profileAt url: URL) throws -> BrowserImportBatch {
    try rejectPrivateProfile(url)
    let isDirectory =
      url.hasDirectoryPath
      || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let directory = isDirectory ? url : url.deletingLastPathComponent()
    let bookmarksURL = directory.appending(path: "Bookmarks.plist")
    let historyURL = directory.appending(path: "History.db")
    guard FileManager.default.fileExists(atPath: bookmarksURL.path),
      FileManager.default.fileExists(atPath: historyURL.path)
    else { throw BrowserImport.ImportError.unsupported }
    let bookmarkItems = try BrowserImport.read(bookmarksURL).map { $0.with(source: source) }
    let historyItems = try SafariHistoryReader.read(historyURL)
    return BrowserImportBatch(source: source, items: bookmarkItems + historyItems)
  }
}

private struct FirefoxProfileImporter: BrowserProfileImporter {
  let source = BrowserImportSource.firefox

  func read(profileAt url: URL) throws -> BrowserImportBatch {
    try rejectPrivateProfile(url)
    let databaseURL =
      url.lastPathComponent == "places.sqlite"
      ? url : url.appending(path: "places.sqlite")
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      throw BrowserImport.ImportError.unsupported
    }
    let bookmarkItems = try FirefoxHistoryReader.bookmarks(databaseURL).map {
      $0.with(source: source)
    }
    let historyItems = try FirefoxHistoryReader.history(databaseURL)
    return BrowserImportBatch(source: source, items: bookmarkItems + historyItems)
  }
}

private func rejectPrivateProfile(_ url: URL) throws {
  let names = url.standardizedFileURL.pathComponents.suffix(3).map { $0.lowercased() }
  let markers = ["incognito", "inprivate", "guest profile", "guest", "private browsing"]
  if names.contains(where: { name in markers.contains(where: name.contains) }) {
    throw BrowserImport.ImportError.privateProfile
  }
}

private enum ChromiumHistoryReader {
  static func read(_ database: URL, source: BrowserImportSource) throws -> [BrowserImportItem] {
    let rows = try BrowserImportSQLite.rows(
      at: database,
      query: """
        SELECT urls.url AS url, urls.title AS title, visits.visit_time AS visit_time
        FROM visits JOIN urls ON urls.id = visits.url
        ORDER BY urls.id, visits.visit_time
        """
    )
    let offset = 11_644_473_600_000_000.0
    return groupedHistory(rows, source: source) { value in
      guard let micros = value.number, micros.isFinite else { return nil }
      let milliseconds = (micros - offset) / 1_000
      guard milliseconds >= 0,
        milliseconds <= Date.distantFuture.timeIntervalSince1970 * 1_000
      else { return nil }
      return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
  }
}

private enum SafariHistoryReader {
  static func read(_ database: URL) throws -> [BrowserImportItem] {
    let rows = try BrowserImportSQLite.rows(
      at: database,
      query: """
        SELECT history_items.url AS url, history_items.title AS title,
               history_visits.visit_time AS visit_time
        FROM history_visits JOIN history_items ON history_items.id = history_visits.history_item
        ORDER BY history_items.id, history_visits.visit_time
        """
    )
    return groupedHistory(rows, source: .safari) { value in
      guard let seconds = value.number, seconds.isFinite, seconds >= 0,
        seconds + 978_307_200 <= Date.distantFuture.timeIntervalSince1970
      else { return nil }
      return Date(timeIntervalSince1970: seconds + 978_307_200)
    }
  }
}

private enum FirefoxHistoryReader {
  static func history(_ database: URL) throws -> [BrowserImportItem] {
    let rows = try BrowserImportSQLite.rows(
      at: database,
      query: """
        SELECT moz_places.url AS url, moz_places.title AS title,
               moz_historyvisits.visit_date AS visit_time
        FROM moz_historyvisits JOIN moz_places ON moz_places.id = moz_historyvisits.place_id
        WHERE moz_historyvisits.visit_type != 5
        ORDER BY moz_places.id, moz_historyvisits.visit_date
        """
    )
    return groupedHistory(rows, source: .firefox) { value in
      guard let micros = value.number, micros.isFinite, micros >= 0,
        micros / 1_000_000 <= Date.distantFuture.timeIntervalSince1970
      else { return nil }
      return Date(timeIntervalSince1970: micros / 1_000_000)
    }
  }

  static func bookmarks(_ database: URL) throws -> [BrowserImportItem] {
    let rows = try BrowserImportSQLite.rows(
      at: database,
      query: """
        SELECT moz_bookmarks.id AS id, moz_bookmarks.type AS type,
               moz_bookmarks.parent AS parent, moz_bookmarks.position AS position,
               moz_bookmarks.title AS title, moz_places.url AS url
        FROM moz_bookmarks LEFT JOIN moz_places ON moz_places.id = moz_bookmarks.fk
        WHERE moz_bookmarks.type IN (1, 2)
        ORDER BY moz_bookmarks.parent, moz_bookmarks.position
        """
    )
    let nodes = rows.compactMap { row -> FirefoxBookmarkNode? in
      guard let id = row["id"]?.integer, let type = row["type"]?.integer,
        let parent = row["parent"]?.integer
      else { return nil }
      return FirefoxBookmarkNode(
        id: id, type: type, parent: parent, title: row["title"]?.string ?? "Untitled",
        address: row["url"]?.string)
    }
    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    var result: [BrowserImportItem] = []
    for node in nodes where node.type == 1 {
      guard let address = node.address, LibraryAddress.destination(address) != nil else { continue }
      var folders: [String] = []
      var parent = node.parent
      var seen: Set<Int64> = []
      while let folder = byID[parent], folder.type == 2, seen.insert(parent).inserted {
        if !["places root", "menu", "toolbar", "unfiled", "mobile", "tags"].contains(
          folder.title.lowercased())
        {
          folders.append(folder.title)
        }
        parent = folder.parent
      }
      result.append(
        BrowserImportItem(
          kind: .bookmark, source: .firefox, title: node.title, address: address,
          folder: folders.reversed().isEmpty ? nil : folders.reversed().joined(separator: " / ")))
    }
    return result
  }
}

private struct FirefoxBookmarkNode {
  let id: Int64
  let type: Int64
  let parent: Int64
  let title: String
  let address: String?
}

private func groupedHistory(
  _ rows: [[String: BrowserImportSQLite.Value]], source: BrowserImportSource,
  date: (BrowserImportSQLite.Value) -> Date?
) -> [BrowserImportItem] {
  var grouped: [String: (String, [Date])] = [:]
  var order: [String] = []
  for row in rows {
    guard let address = row["url"]?.string, LibraryAddress.destination(address) != nil,
      let rawVisit = row["visit_time"], let visit = date(rawVisit)
    else { continue }
    if grouped[address] == nil { order.append(address) }
    let title = row["title"]?.string ?? ""
    var existing = grouped[address] ?? (title, [])
    if !title.isEmpty { existing.0 = title }
    existing.1.append(visit)
    grouped[address] = existing
  }
  return order.compactMap { address in
    guard let (title, visits) = grouped[address], !visits.isEmpty else { return nil }
    return BrowserImportItem(
      kind: .history, source: source, title: title, address: address,
      visitTimes: visits.sorted())
  }
}

extension BrowserImportSQLite.Value {
  fileprivate var integer: Int64? {
    if case .integer(let value) = self { return value }
    return nil
  }

  fileprivate var number: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .real(let value): value
    case .text, .null: nil
    }
  }

  fileprivate var string: String? {
    if case .text(let value) = self { return value }
    return nil
  }
}
