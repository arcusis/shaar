// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func historyInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

private func historyTimestamps(_ value: Any?) -> [Int64]? {
  guard let values = value as? [Any] else { return nil }
  let timestamps = values.map { value -> Int64? in
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return Int64(exactly: number.doubleValue)
  }
  guard timestamps.allSatisfy({ $0 != nil }) else { return nil }
  return timestamps.compactMap { $0 }
}

public enum ShaarHistoryOperation: UInt32, Sendable {
  case query = 600
  case insert = 601
  case delete = 602
  case watch = 603
  case unwatch = 604
}

public struct ShaarHistoryEntry: Equatable, Sendable {
  public let url: URL
  public let title: String
  public let visitCount: Int
  public let visits: [Int64]
}

public struct ShaarHistoryInsertPage: Codable, Equatable, Sendable {
  public let url: String
  public let title: String?
  public let visits: [Int64]

  public init(url: String, title: String? = nil, visits: [Int64]) {
    self.url = url
    self.title = title
    self.visits = visits
  }
}

public struct ShaarHistoryInsertResult: Equatable, Sendable {
  public struct Rejection: Equatable, Sendable {
    public let index: Int
    public let code: String
  }
  public let accepted: Int
  public let insertedVisits: Int
  public let duplicateVisits: Int
  public let rejected: [Rejection]
}

public enum ShaarHistoryEventRouter {
  /// Returns only a known regular-profile invalidation. Private-session and
  /// malformed event envelopes never enter a regular library cache.
  public static func changedProfile(for event: ShaarCopiedEvent, knownProfiles: Set<UUID>) -> UUID?
  {
    guard event.kind == 11, event.sessionID.isEmpty,
      let profileString = String(data: event.profileID, encoding: .utf8),
      let profileID = UUID(uuidString: profileString), knownProfiles.contains(profileID),
      let object = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      historyInteger(object["schemaVersion"]) == 1,
      let kind = object["kind"] as? String,
      ["changed", "visit", "modified", "deleted"].contains(kind)
    else { return nil }
    return profileID
  }
}

/// The engine binding supplies this with the selected profile handle. Keeping scope
/// outside the payload prevents an import from silently falling back to another profile.
public protocol ShaarHistorySubmitting: Sendable {
  func submitHistory(
    profileID: UUID,
    operation: ShaarHistoryOperation,
    argsJSON: Data
  ) async throws -> Data
}

public enum ShaarHistoryAdapterError: Error, Equatable, Sendable {
  case invalidResponse(String)
}

public struct ShaarHistoryAdapter: Sendable {
  private let engine: any ShaarHistorySubmitting
  public init(engine: any ShaarHistorySubmitting) { self.engine = engine }

  public func query(
    profileID: UUID, maxUrls: Int = 500, maxVisitsPerURL: Int = 1,
    search: String? = nil
  )
    async throws -> [ShaarHistoryEntry]
  {
    guard (1...5000).contains(maxUrls), (1...50).contains(maxVisitsPerURL) else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid query bounds")
    }
    var args: [String: Any] = [
      "schemaVersion": 1, "maxUrls": maxUrls,
      "maxVisitsPerUrl": maxVisitsPerURL,
    ]
    if let search {
      guard search.utf8.count <= 4096 else {
        throw ShaarHistoryAdapterError.invalidResponse("search query is too long")
      }
      args["search"] = search
    }
    let data = try await engine.submitHistory(
      profileID: profileID, operation: .query,
      argsJSON: try json(args))
    let root = try object(data, required: ["schemaVersion", "entries"], optional: ["nextCursor"])
    try version(root)
    guard let rows = root["entries"] as? [[String: Any]], rows.count <= maxUrls else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid entries")
    }
    var seen = Set<String>()
    return try rows.map { row in
      guard Set(row.keys) == Set(["url", "title", "visitCount", "visits"]),
        let rawURL = row["url"] as? String, let url = URL(string: rawURL),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        let title = row["title"] as? String,
        let count = historyInteger(row["visitCount"]), count >= 0,
        let visits = historyTimestamps(row["visits"]), visits.count <= maxVisitsPerURL,
        count >= visits.count,
        visits.allSatisfy({ $0 >= 0 }), seen.insert(rawURL).inserted
      else { throw ShaarHistoryAdapterError.invalidResponse("malformed or duplicate history row") }
      return ShaarHistoryEntry(url: url, title: title, visitCount: count, visits: visits)
    }
  }

  public func delete(profileID: UUID, urls: [URL]) async throws -> Int {
    let strings = urls.map(\.absoluteString)
    guard (1...500).contains(urls.count), Set(strings).count == strings.count,
      urls.allSatisfy({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
    else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid delete URLs")
    }
    let data = try await engine.submitHistory(
      profileID: profileID, operation: .delete,
      argsJSON: try json(["schemaVersion": 1, "urls": strings]))
    let root = try object(data, required: ["schemaVersion", "deleted"], optional: [])
    try version(root)
    guard let count = historyInteger(root["deleted"]), (0...urls.count).contains(count) else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid delete result")
    }
    return count
  }

  public func insert(profileID: UUID, source: String, pages: [ShaarHistoryInsertPage]) async throws
    -> ShaarHistoryInsertResult
  {
    guard ["safari", "chrome", "arc", "firefox"].contains(source),
      (1...5000).contains(pages.count),
      pages.allSatisfy({ page in
        guard let url = URL(string: page.url),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil
        else { return false }
        return !page.visits.isEmpty && page.visits.allSatisfy({ $0 >= 0 })
      })
    else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid import batch")
    }
    let encoder = JSONEncoder()
    let pageData = try encoder.encode(pages)
    guard let payload = try JSONSerialization.jsonObject(with: pageData) as? [[String: Any]] else {
      throw ShaarHistoryAdapterError.invalidResponse("could not encode import pages")
    }
    let request = try json(["schemaVersion": 1, "source": source, "pages": payload])
    let data = try await engine.submitHistory(
      profileID: profileID, operation: .insert, argsJSON: request)
    let root = try object(
      data,
      required: ["schemaVersion", "accepted", "insertedVisits", "duplicateVisits", "rejected"],
      optional: [])
    try version(root)
    guard let accepted = historyInteger(root["accepted"]), accepted >= 0,
      let inserted = historyInteger(root["insertedVisits"]), inserted >= 0,
      let duplicates = historyInteger(root["duplicateVisits"]), duplicates >= 0,
      let rawRejected = root["rejected"] as? [[String: Any]]
    else {
      throw ShaarHistoryAdapterError.invalidResponse("malformed insert result")
    }
    var rejectedIndexes = Set<Int>()
    let rejected = try rawRejected.map { item -> ShaarHistoryInsertResult.Rejection in
      guard Set(item.keys) == Set(["index", "code"]), let index = historyInteger(item["index"]),
        pages.indices.contains(index), rejectedIndexes.insert(index).inserted,
        let code = item["code"] as? String, !code.isEmpty
      else {
        throw ShaarHistoryAdapterError.invalidResponse("malformed row rejection")
      }
      return .init(index: index, code: code)
    }
    guard accepted + rejected.count == pages.count else {
      throw ShaarHistoryAdapterError.invalidResponse("inconsistent insert counts")
    }
    return .init(
      accepted: accepted, insertedVisits: inserted, duplicateVisits: duplicates, rejected: rejected)
  }

  public func watch(profileID: UUID) async throws -> String {
    let data = try await engine.submitHistory(
      profileID: profileID, operation: .watch,
      argsJSON: try json(["schemaVersion": 1]))
    let root = try object(data, required: ["schemaVersion", "subscriptionId"], optional: [])
    try version(root)
    guard let token = root["subscriptionId"] as? String, !token.isEmpty else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid subscription token")
    }
    return token
  }

  public func unwatch(profileID: UUID, subscriptionID: String) async throws {
    guard !subscriptionID.isEmpty else {
      throw ShaarHistoryAdapterError.invalidResponse("empty subscription token")
    }
    let data = try await engine.submitHistory(
      profileID: profileID, operation: .unwatch,
      argsJSON: try json(["schemaVersion": 1, "subscriptionId": subscriptionID]))
    let root = try object(data, required: ["schemaVersion"], optional: [])
    try version(root)
  }

  private func json(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  private func object(_ data: Data, required: Set<String>, optional: Set<String>) throws -> [String:
    Any]
  {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      required.isSubset(of: Set(root.keys)), Set(root.keys).isSubset(of: required.union(optional))
    else {
      throw ShaarHistoryAdapterError.invalidResponse("invalid response object")
    }
    return root
  }
  private func version(_ root: [String: Any]) throws {
    guard historyInteger(root["schemaVersion"]) == 1 else {
      throw ShaarHistoryAdapterError.invalidResponse("unsupported schema version")
    }
  }
}
