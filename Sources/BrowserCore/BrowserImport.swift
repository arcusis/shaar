// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct BrowserImportItem: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable { case bookmark, history }
  public let id: UUID
  public let kind: Kind
  public let title: String
  public let address: String
  public let folder: String?

  public init(
    id: UUID = UUID(), kind: Kind = .bookmark, title: String, address: String, folder: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.address = address
    self.folder = folder
  }
}

/// Reads browser export files without opening the source browser's profile database.
public enum BrowserImport {
  public static func read(_ url: URL) throws -> [BrowserImportItem] {
    let data = try Data(contentsOf: url)
    if url.pathExtension.lowercased() == "html" {
      guard let html = String(data: data, encoding: .utf8) else { throw ImportError.unsupported }
      return htmlBookmarks(html)
    }
    if url.pathExtension.lowercased() == "plist" {
      let object = try PropertyListSerialization.propertyList(from: data, format: nil)
      guard let root = object as? [String: Any] else { throw ImportError.unsupported }
      return safari(root)
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any] else { throw ImportError.unsupported }
    if let roots = root["roots"] as? [String: Any] {
      return chromium(roots)
    }
    // Firefox's JSON bookmark backups contain the same recursive title/URI shape.
    if root["type"] as? String == "text/x-moz-place-container" || root["children"] != nil {
      return firefox(root)
    }
    throw ImportError.unsupported
  }

  public static func operations(for items: [BrowserImportItem], otherFolderID: UUID) -> [[String:
    Any]]
  {
    var operations: [[String: Any]] = []
    var folders: [String: UUID] = [:]
    for item in items where item.kind == .bookmark {
      let parent: UUID
      if let folder = item.folder {
        var currentParent = otherFolderID
        var path = ""
        for component in folder.components(separatedBy: " / ") {
          path = path.isEmpty ? component : "\(path) / \(component)"
          if let existing = folders[path] {
            currentParent = existing
          } else {
            let id = UUID()
            folders[path] = id
            operations.append([
              "op": "add", "id": id.uuidString.lowercased(),
              "parent": currentParent.uuidString.lowercased(), "k": "f", "t": component,
            ])
            currentParent = id
          }
        }
        parent = currentParent
      } else {
        parent = otherFolderID
      }
      operations.append([
        "op": "add", "id": item.id.uuidString.lowercased(),
        "parent": parent.uuidString.lowercased(), "k": "u", "t": item.title, "u": item.address,
      ])
    }
    return operations
  }

  @MainActor
  public static func apply(
    _ operations: [[String: Any]],
    using applyOperation:
      @escaping @MainActor (
        [String: Any], @escaping @MainActor (Error?) -> Void
      ) -> Void,
    completion: @escaping @MainActor (Error?) -> Void
  ) {
    guard let first = operations.first else {
      completion(nil)
      return
    }
    applyOperation(first) { error in
      guard error == nil else {
        completion(error)
        return
      }
      apply(
        Array(operations.dropFirst()), using: applyOperation, completion: completion)
    }
  }

  private static func chromium(_ roots: [String: Any]) -> [BrowserImportItem] {
    var result: [BrowserImportItem] = []
    for key in ["bookmark_bar", "other", "synced"] {
      if let root = roots[key] as? [String: Any] {
        walk(root["children"] as? [[String: Any]] ?? [], path: nil, into: &result)
      }
    }
    return result
  }

  private static func safari(_ root: [String: Any]) -> [BrowserImportItem] {
    var result: [BrowserImportItem] = []
    walkSafari(root["Children"] as? [[String: Any]] ?? [], path: nil, into: &result)
    return result
  }

  private static func walkSafari(
    _ nodes: [[String: Any]], path: String?, into result: inout [BrowserImportItem]
  ) {
    for node in nodes {
      let title = node["Title"] as? String ?? "Untitled"
      if let address = node["URLString"] as? String, valid(address) {
        result.append(
          .init(id: UUID(), kind: .bookmark, title: title, address: address, folder: path))
      } else {
        walkSafari(
          node["Children"] as? [[String: Any]] ?? [],
          path: path.map { "\($0) / \(title)" } ?? title, into: &result)
      }
    }
  }

  private static func firefox(_ root: [String: Any]) -> [BrowserImportItem] {
    var result: [BrowserImportItem] = []
    walk([root], path: nil, into: &result)
    return result
  }

  /// Firefox's exported bookmarks.html uses the standard Netscape bookmark format.
  private static func htmlBookmarks(_ html: String) -> [BrowserImportItem] {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?is)<A\b[^>]*HREF\s*=\s*["']([^"']+)["'][^>]*>(.*?)</A>"#)
    else { return [] }
    let range = NSRange(html.startIndex..., in: html)
    return expression.matches(in: html, range: range).compactMap { match in
      guard let urlRange = Range(match.range(at: 1), in: html),
        let titleRange = Range(match.range(at: 2), in: html)
      else { return nil }
      let address = String(html[urlRange])
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
      guard valid(address) else { return nil }
      let title = String(html[titleRange]).replacingOccurrences(
        of: "<[^>]+>", with: "", options: .regularExpression
      )
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      return BrowserImportItem(
        id: UUID(), kind: .bookmark, title: title, address: address, folder: nil)
    }
  }

  private static func walk(
    _ nodes: [[String: Any]], path: String?, into result: inout [BrowserImportItem]
  ) {
    for node in nodes {
      let title = node["name"] as? String ?? node["title"] as? String ?? "Untitled"
      let address = node["url"] as? String ?? node["uri"] as? String
      if let address, valid(address) {
        result.append(
          .init(id: UUID(), kind: .bookmark, title: title, address: address, folder: path))
      } else if let children = node["children"] as? [[String: Any]] ?? node["c"] as? [[String: Any]]
      {
        walk(children, path: path.map { "\($0) / \(title)" } ?? title, into: &result)
      }
    }
  }

  private static func valid(_ value: String) -> Bool {
    LibraryAddress.destination(value) != nil
  }

  public enum ImportError: Error, LocalizedError {
    case unsupported
    public var errorDescription: String? {
      "Choose a Safari Bookmarks.plist, a Chrome or Arc Bookmarks file, or an exported Firefox bookmarks HTML or JSON file."
    }
  }
}
