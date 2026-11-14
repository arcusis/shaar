// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

private struct BrowserImportFolderKey: Hashable {
  let parentID: UUID
  let name: String
}

public struct BrowserImportItem: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable { case bookmark, history }
  public let id: UUID
  public let kind: Kind
  public let source: BrowserImportSource
  public let title: String
  public let address: String
  public let folder: String?
  public let folderComponents: [String]?
  public let visitTimes: [Date]

  public init(
    id: UUID = UUID(), kind: Kind = .bookmark, source: BrowserImportSource = .chrome,
    title: String, address: String, folder: String? = nil, folderComponents: [String]? = nil,
    visitTimes: [Date] = []
  ) {
    self.id = id
    self.kind = kind
    self.source = source
    self.title = title
    self.address = address
    self.folder = folder
    self.folderComponents =
      folderComponents
      ?? folder.map { $0.components(separatedBy: " / ") }
    self.visitTimes = visitTimes
  }
}

/// Reads browser export files without opening the source browser's profile database.
public enum BrowserImport {
  public static func read(_ url: URL) throws -> [BrowserImportItem] {
    let data = try Data(contentsOf: url)
    if ["html", "htm"].contains(url.pathExtension.lowercased()) {
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

  public static func readProfile(at url: URL, source: BrowserImportSource) throws
    -> BrowserImportBatch
  {
    try BrowserProfileImporters.importer(for: source).read(profileAt: url)
  }

  public static func read(_ url: URL, source: BrowserImportSource) throws -> BrowserImportBatch {
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    if isDirectory { return try readProfile(at: url, source: source) }
    let items = try read(url).map { $0.with(source: source) }
    return BrowserImportBatch(source: source, items: items)
  }

  /// Reads a browser export without blocking the caller's actor on file or database work.
  public static func readOffMain(_ url: URL, source: BrowserImportSource) async throws
    -> BrowserImportBatch
  {
    try await Task.detached(priority: .userInitiated) {
      try read(url, source: source)
    }.value
  }

  public static func historyRows(for items: [BrowserImportItem]) -> [[String: Any]] {
    items.compactMap { item in
      guard item.kind == .history, !item.visitTimes.isEmpty else { return nil }
      var visits: [Double] = []
      visits.reserveCapacity(item.visitTimes.count)
      var latest: Date?
      for visit in item.visitTimes {
        visits.append(visit.timeIntervalSince1970 * 1_000)
        if let current = latest {
          if current < visit { latest = visit }
        } else {
          latest = visit
        }
      }
      guard let latest else { return nil }
      return [
        "u": item.address, "t": item.title, "n": visits.count,
        "l": latest.timeIntervalSince1970 * 1_000,
        "v": visits, "s": item.source.rawValue,
      ]
    }
  }

  public static func operations(for items: [BrowserImportItem], otherFolderID: UUID) -> [[String:
    Any]]
  {
    var operations: [[String: Any]] = []
    var folders: [BrowserImportFolderKey: UUID] = [:]
    for item in items where item.kind == .bookmark {
      let parent: UUID
      if let components = item.folderComponents {
        var currentParent = otherFolderID
        for component in components {
          let key = BrowserImportFolderKey(parentID: currentParent, name: component)
          if let existing = folders[key] {
            currentParent = existing
          } else {
            let id = UUID()
            folders[key] = id
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
    var index = 0
    var isApplying = false

    func advance() {
      guard !isApplying else { return }
      isApplying = true
      while index < operations.count {
        let operation = operations[index]
        index += 1
        var completedSynchronously = false
        var synchronousError: Error?
        var callbackConsumed = false
        applyOperation(operation) { error in
          guard !callbackConsumed else { return }
          callbackConsumed = true
          if isApplying {
            completedSynchronously = true
            synchronousError = error
          } else if let error {
            completion(error)
          } else {
            advance()
          }
        }
        guard completedSynchronously else {
          isApplying = false
          return
        }
        if let synchronousError {
          isApplying = false
          completion(synchronousError)
          return
        }
      }
      isApplying = false
      completion(nil)
    }

    advance()
  }

  private static func chromium(_ roots: [String: Any]) -> [BrowserImportItem] {
    var result: [BrowserImportItem] = []
    for key in ["bookmark_bar", "other", "synced", "mobile"] {
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
    _ nodes: [[String: Any]], path: [String]?, into result: inout [BrowserImportItem]
  ) {
    for node in nodes {
      if let address = node["URLString"] as? String, valid(address) {
        result.append(
          .init(
            id: UUID(), kind: .bookmark,
            title: importTitle(node["Title"] as? String, fallback: "Untitled bookmark"),
            address: address,
            folder: path?.joined(separator: " / "), folderComponents: path))
      } else {
        walkSafari(
          node["Children"] as? [[String: Any]] ?? [],
          path: (path ?? [])
            + [importTitle(node["Title"] as? String, fallback: "Untitled folder")], into: &result)
      }
    }
  }

  private static func firefox(_ root: [String: Any]) -> [BrowserImportItem] {
    var result: [BrowserImportItem] = []
    if root["guid"] as? String == "root________",
      root["type"] as? String == "text/x-moz-place-container"
    {
      walk(root["children"] as? [[String: Any]] ?? [], path: nil, into: &result)
    } else {
      walk([root], path: nil, into: &result)
    }
    return result
  }

  /// Firefox's exported bookmarks.html uses the standard Netscape bookmark format.
  private static func htmlBookmarks(_ html: String) -> [BrowserImportItem] {
    let html = html.replacingOccurrences(
      of: #"(?s)<!--.*?(?:-->|$)"#, with: "", options: .regularExpression)
    guard
      let expression = try? NSRegularExpression(
        pattern:
          #"(?is)<H3\b[^>]*>(.*?)</H3>|<A\b[^>]*\bHREF\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>(.*?)</A>|</?DL\b[^>]*>"#
      )
    else { return [] }
    let range = NSRange(html.startIndex..., in: html)
    var result: [BrowserImportItem] = []
    var folderStack: [String] = []
    var pendingFolder: String?

    for match in expression.matches(in: html, range: range) {
      if let headingRange = Range(match.range(at: 1), in: html) {
        pendingFolder = importTitle(
          htmlText(String(html[headingRange])), fallback: "Untitled folder")
        continue
      }
      let addressRange =
        Range(match.range(at: 2), in: html)
        ?? Range(match.range(at: 3), in: html)
        ?? Range(match.range(at: 4), in: html)
      if let addressRange, let titleRange = Range(match.range(at: 5), in: html) {
        let address = htmlText(String(html[addressRange]))
        guard valid(address) else { continue }
        let title = importTitle(
          htmlText(String(html[titleRange])), fallback: "Untitled bookmark")
        let folder = folderStack.isEmpty ? nil : folderStack.joined(separator: " / ")
        result.append(
          BrowserImportItem(
            id: UUID(), kind: .bookmark, title: title, address: address, folder: folder,
            folderComponents: folderStack))
        continue
      }

      guard let tokenRange = Range(match.range, in: html) else { continue }
      let token = html[tokenRange].lowercased()
      if token.hasPrefix("</dl") {
        if !folderStack.isEmpty { folderStack.removeLast() }
      } else if token.hasPrefix("<dl"), let folder = pendingFolder {
        folderStack.append(folder)
        pendingFolder = nil
      }
    }
    return result
  }

  private static func htmlText(_ value: String) -> String {
    let text = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      if text[index] == "&", let end = text[index...].firstIndex(of: ";"),
        text.distance(from: index, to: end) <= 12
      {
        let entity = String(text[text.index(after: index)..<end])
        if let decoded = decodeHTMLEntity(entity) {
          result.unicodeScalars.append(contentsOf: decoded.unicodeScalars)
          index = text.index(after: end)
          continue
        }
      }
      result.append(text[index])
      index = text.index(after: index)
    }
    return result
  }

  private static func decodeHTMLEntity(_ entity: String) -> String? {
    switch entity {
    case "amp", "AMP": return "&"
    case "quot": return "\""
    case "apos": return "'"
    case "lt": return "<"
    case "gt": return ">"
    case "nbsp": return "\u{00a0}"
    default: break
    }

    guard entity.first == "#" else { return nil }
    let isHex = entity.dropFirst().first == "x" || entity.dropFirst().first == "X"
    let digits = entity.dropFirst(isHex ? 2 : 1)
    guard let value = UInt32(digits, radix: isHex ? 16 : 10),
      let scalar = UnicodeScalar(value)
    else { return nil }
    return String(scalar)
  }

  private static func walk(
    _ nodes: [[String: Any]], path: [String]?, into result: inout [BrowserImportItem]
  ) {
    for node in nodes {
      let rawTitle = node["name"] as? String ?? node["title"] as? String
      let address = node["url"] as? String ?? node["uri"] as? String
      if let address, valid(address) {
        result.append(
          .init(
            id: UUID(), kind: .bookmark,
            title: importTitle(rawTitle, fallback: "Untitled bookmark"), address: address,
            folder: path?.joined(separator: " / "), folderComponents: path))
      } else if let children = node["children"] as? [[String: Any]] ?? node["c"] as? [[String: Any]]
      {
        walk(
          children,
          path: (path ?? []) + [importTitle(rawTitle, fallback: "Untitled folder")],
          into: &result)
      }
    }
  }

  private static func importTitle(_ value: String?, fallback: String) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return BrowserLocalization.string(fallback)
    }
    return value
  }

  private static func valid(_ value: String) -> Bool {
    LibraryAddress.destination(value) != nil
  }

  public enum ImportError: Error, LocalizedError {
    case unsupported
    case privateProfile
    case databaseUnavailable(String)
    case tooManyRows
    public var errorDescription: String? {
      description(language: .currentLaunchLanguage)
    }

    public func description(language: BrowserLanguage) -> String {
      switch self {
      case .unsupported:
        BrowserLocalization.string(
          "Choose a Chrome, Edge, Brave, Arc, Safari, or Firefox profile folder or bookmark export.",
          language: language)
      case .privateProfile:
        BrowserLocalization.string(
          "Private browser profiles cannot be imported. Choose a regular profile.",
          language: language)
      case .databaseUnavailable:
        BrowserLocalization.string(
          "The selected browser history database could not be read safely.", language: language)
      case .tooManyRows:
        BrowserLocalization.string(
          "The selected browser profile contains more data than can be imported at once.",
          language: language)
      }
    }
  }
}

extension BrowserImportItem {
  func with(source: BrowserImportSource) -> BrowserImportItem {
    BrowserImportItem(
      id: id, kind: kind, source: source, title: title, address: address, folder: folder,
      folderComponents: folderComponents, visitTimes: visitTimes)
  }
}
