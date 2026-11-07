// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarSourceTreeRow: Identifiable, Equatable {
  let id: String
  let name: String
  let depth: Int
  let resourceURL: String?
}

enum ShaarSourceTree {
  static func rows(for resources: [ShaarSourceResource]) -> [ShaarSourceTreeRow] {
    let root = Node()
    for resource in resources {
      let parts = pathParts(resource)
      guard let file = parts.last else { continue }
      var cursor = root
      for folder in parts.dropLast() {
        let child = cursor.folders[folder] ?? Node()
        cursor.folders[folder] = child
        cursor = child
      }
      cursor.files.append((file, resource.url))
    }
    var rows: [ShaarSourceTreeRow] = []
    flatten(root, name: nil, depth: 0, path: "", into: &rows)
    return rows
  }

  static func sameResource(_ loaded: String, _ frame: String) -> Bool {
    if loaded == frame { return true }
    guard var left = URLComponents(string: loaded),
      var right = URLComponents(string: frame)
    else { return false }
    left.fragment = nil
    right.fragment = nil
    left.query = nil
    right.query = nil
    return left.scheme == right.scheme && left.host == right.host
      && left.port == right.port && left.path == right.path
  }

  private final class Node {
    var folders: [String: Node] = [:]
    var files: [(String, String)] = []
  }

  private static func pathParts(_ resource: ShaarSourceResource) -> [String] {
    guard let components = URLComponents(string: resource.url) else { return [resource.name] }
    var parts = components.path.split(separator: "/").map(String.init)
    if let host = components.host, !host.isEmpty { parts.insert(host, at: 0) }
    if parts.isEmpty { parts = [resource.name] }
    return parts
  }

  private static func flatten(
    _ node: Node, name: String?, depth: Int, path: String, into rows: inout [ShaarSourceTreeRow]
  ) {
    if let name {
      rows.append(
        ShaarSourceTreeRow(id: "folder:\(path)", name: name, depth: depth, resourceURL: nil))
    }
    let childDepth = name == nil ? depth : depth + 1
    for folder in node.folders.keys.sorted() {
      guard let child = node.folders[folder] else { continue }
      flatten(child, name: folder, depth: childDepth, path: path + "/" + folder, into: &rows)
    }
    let files = node.files.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    for file in files {
      rows.append(
        ShaarSourceTreeRow(
          id: "file:\(file.1)", name: file.0, depth: childDepth, resourceURL: file.1))
    }
  }
}
