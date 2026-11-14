// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum LibrarySection: String, CaseIterable, Sendable {
  case bookmarks, history

  public var title: String {
    BrowserLocalization.string(self == .bookmarks ? "Bookmarks" : "History")
  }
}

public enum LibraryDataError: Error, LocalizedError {
  case invalidBookmarks, invalidHistory

  public var errorDescription: String? {
    switch self {
    case .invalidBookmarks: BrowserLocalization.string("The engine returned invalid bookmark data.")
    case .invalidHistory: BrowserLocalization.string("The engine returned invalid history data.")
    }
  }
}

public struct BrowserBookmark: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let profileID: UUID
  public let parentID: UUID?
  public let title: String
  public let address: String?
  public let depth: Int
  public let path: String
  public let isPermanent: Bool
  public var isFolder: Bool { address == nil }
  public var destination: URL? { address.flatMap(LibraryAddress.destination) }
}

public struct BookmarkTree: Equatable, Sendable {
  public let profileID: UUID
  public let barID: UUID
  public let otherID: UUID
  public let items: [BrowserBookmark]
  private let parents: [UUID: UUID]

  public init(profileID: UUID, payload: [String: Any]) throws {
    guard let bar = payload["bar"] as? [String: Any],
      let other = payload["other"] as? [String: Any],
      let barID = (bar["id"] as? String).flatMap(UUID.init(uuidString:)),
      let otherID = (other["id"] as? String).flatMap(UUID.init(uuidString:)), barID != otherID,
      bar["k"] as? String == "f", other["k"] as? String == "f"
    else { throw LibraryDataError.invalidBookmarks }
    self.profileID = profileID
    self.barID = barID
    self.otherID = otherID
    var items: [BrowserBookmark] = []
    var ids: Set<UUID> = []
    var parents: [UUID: UUID] = [:]
    var stack: [(node: [String: Any], parent: UUID?, depth: Int, path: String)] = [
      (other, nil, 0, ""), (bar, nil, 0, ""),
    ]
    while let (node, parent, depth, path) = stack.popLast() {
      guard let id = (node["id"] as? String).flatMap(UUID.init(uuidString:)),
        ids.insert(id).inserted, let title = node["t"] as? String,
        let kind = node["k"] as? String, ["f", "u"].contains(kind)
      else { throw LibraryDataError.invalidBookmarks }
      if let parent { parents[id] = parent }
      let text =
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? Self.untitledBookmarkTitle(kind: kind) : title
      let ownPath = path.isEmpty ? text : "\(path) / \(text)"
      let address: String?
      if kind == "u" {
        guard let value = node["u"] as? String, LibraryAddress.isValid(value) else {
          throw LibraryDataError.invalidBookmarks
        }
        address = value
      } else {
        guard let children = node["c"] as? [[String: Any]] else {
          throw LibraryDataError.invalidBookmarks
        }
        address = nil
        for child in children.reversed() { stack.append((child, id, depth + 1, ownPath)) }
      }
      items.append(
        BrowserBookmark(
          id: id, profileID: profileID, parentID: parent, title: text, address: address,
          depth: depth, path: ownPath, isPermanent: parent == nil))
    }
    self.items = items
    self.parents = parents
  }

  public func contains(_ ancestor: UUID, inPathTo id: UUID) -> Bool {
    guard id == barID || id == otherID || parents[id] != nil else { return false }
    var current: UUID? = id
    while let id = current {
      if id == ancestor { return true }
      current = parents[id]
    }
    return false
  }

  private static func untitledBookmarkTitle(kind: String) -> String {
    BrowserLocalization.string(kind == "f" ? "Untitled folder" : "Untitled bookmark")
  }
}

public struct BrowserHistoryEntry: Identifiable, Equatable, Sendable {
  public var id: String { address }
  public let profileID: UUID
  public let address: String
  public let title: String
  public let visitCount: Int64
  public let lastVisit: Date
  public var destination: URL? { LibraryAddress.destination(address) }

  public init(profileID: UUID, payload: [String: Any]) throws {
    guard let address = payload["u"] as? String, LibraryAddress.isValid(address),
      let title = payload["t"] as? String, let count = payload["n"] as? NSNumber,
      CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue.isFinite,
      count.doubleValue >= 0, count.doubleValue < Double(Int64.max),
      count.doubleValue.rounded(.towardZero) == count.doubleValue,
      let visits = payload["v"] as? [NSNumber], !visits.isEmpty
    else { throw LibraryDataError.invalidHistory }
    let maximumVisit = Date.distantFuture.timeIntervalSince1970 * 1_000
    var last = 0.0
    for visit in visits {
      let value = visit.doubleValue
      guard CFGetTypeID(visit) != CFBooleanGetTypeID(), value.isFinite,
        value >= 0, value <= maximumVisit
      else { throw LibraryDataError.invalidHistory }
      last = max(last, value)
    }
    self.profileID = profileID
    self.address = address
    self.title =
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? URL(string: address)?.host() ?? address : title
    visitCount = count.int64Value
    lastVisit = Date(timeIntervalSince1970: last / 1000)
  }

  static func latestValidVisit(in visits: [NSNumber]) -> Double? {
    guard !visits.isEmpty else { return nil }
    let latestAllowed = Date.distantFuture.timeIntervalSince1970 * 1000
    var latest = 0.0
    for (index, visit) in visits.enumerated() {
      let value = visit.doubleValue
      guard CFGetTypeID(visit) != CFBooleanGetTypeID(), value.isFinite, value >= 0,
        value <= latestAllowed
      else { return nil }
      if index == 0 || value > latest { latest = value }
    }
    return latest
  }

  static func validatedLatestVisit(in visits: [NSNumber]) -> Double? {
    latestValidVisit(in: visits)
  }
}

public enum LibraryAddress {
  public static func isValid(_ value: String) -> Bool {
    guard value.utf8.count <= 32768, !value.contains("\0"),
      let url = URL(string: value), let scheme = url.scheme?.lowercased()
    else { return false }
    return !["http", "https"].contains(scheme) || NavigationInput.isWebURL(url)
  }

  public static func destination(_ value: String) -> URL? {
    guard value.utf8.count <= 32768, !value.contains("\0"),
      let url = URL(string: value), NavigationInput.isWebURL(url)
    else {
      return nil
    }
    return url
  }
}
