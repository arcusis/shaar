// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum LibrarySection: String, CaseIterable, Sendable {
  case bookmarks, history

  public var title: String { self == .bookmarks ? "Bookmarks" : "History" }
}

public enum LibraryDataError: Error, LocalizedError {
  case invalidBookmarks, invalidHistory

  public var errorDescription: String? {
    switch self {
    case .invalidBookmarks: "The engine returned invalid bookmark data."
    case .invalidHistory: "The engine returned invalid history data."
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
    var stack: [(node: [String: Any], parent: UUID?, depth: Int, path: String)] = [
      (other, nil, 0, ""), (bar, nil, 0, ""),
    ]
    while let (node, parent, depth, path) = stack.popLast() {
      guard let id = (node["id"] as? String).flatMap(UUID.init(uuidString:)),
        ids.insert(id).inserted, let title = node["t"] as? String,
        let kind = node["k"] as? String, ["f", "u"].contains(kind)
      else { throw LibraryDataError.invalidBookmarks }
      let text = title.isEmpty ? (kind == "f" ? "Untitled folder" : "Untitled bookmark") : title
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
  }

  public func contains(_ ancestor: UUID, inPathTo id: UUID) -> Bool {
    let nodes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    var current: UUID? = id
    while let id = current, let node = nodes[id] {
      if id == ancestor { return true }
      current = node.parentID
    }
    return false
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
      let visits = payload["v"] as? [NSNumber], !visits.isEmpty,
      visits.allSatisfy({
        CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0
          && $0.doubleValue <= Date.distantFuture.timeIntervalSince1970 * 1000
      }),
      let last = visits.map(\.doubleValue).max()
    else { throw LibraryDataError.invalidHistory }
    self.profileID = profileID
    self.address = address
    self.title = title.isEmpty ? URL(string: address)?.host() ?? address : title
    visitCount = count.int64Value
    lastVisit = Date(timeIntervalSince1970: last / 1000)
  }
}

public enum LibraryAddress {
  public static func isValid(_ value: String) -> Bool {
    value.utf8.count <= 32768 && !value.contains("\0") && URL(string: value)?.scheme != nil
  }

  public static func destination(_ value: String) -> URL? {
    guard isValid(value), let url = URL(string: value), NavigationInput.isWebURL(url) else {
      return nil
    }
    return url
  }
}
