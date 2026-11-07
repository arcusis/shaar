// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarOriginalSource {
  let url: String
  let content: String
  let mimeType: String
}

enum ShaarSourceMap {
  static let maximumBytes = 5 * 1_048_576

  static func load(
    from script: String, resourceURL: URL,
    fetch: @Sendable (URL) async throws -> Data
  ) async throws -> [ShaarOriginalSource] {
    guard let reference = DevelopmentSourceResolver.sourceMapReference(in: script) else { return [] }
    let data: Data
    if reference.hasPrefix("data:") {
      guard let decoded = inlineData(reference) else { return [] }
      data = decoded
    } else {
      guard let url = URL(string: reference, relativeTo: resourceURL)?.absoluteURL,
        url.user == nil, url.password == nil,
        DevelopmentSourceResolver.sameOrigin(url, resourceURL)
      else { return [] }
      data = try await fetch(url)
    }
    return originals(in: data, resourceURL: resourceURL)
  }

  private static func inlineData(_ reference: String) -> Data? {
    guard reference.utf8.count <= maximumBytes * 2,
      let comma = reference.firstIndex(of: ",")
    else { return nil }
    let header = reference[..<comma].lowercased()
    guard header.hasPrefix("data:application/json") else { return nil }
    let payload = String(reference[reference.index(after: comma)...])
    let data: Data?
    if header.hasSuffix(";base64") {
      data = Data(base64Encoded: payload)
    } else {
      data = payload.removingPercentEncoding?.data(using: .utf8)
    }
    guard let data, data.count <= maximumBytes else { return nil }
    return data
  }

  private static func originals(in data: Data, resourceURL: URL) -> [ShaarOriginalSource] {
    guard data.count <= maximumBytes,
      let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      map["version"] as? Int == 3,
      let sources = map["sources"] as? [String], sources.count <= 512,
      let contents = map["sourcesContent"] as? [Any], contents.count == sources.count
    else { return [] }
    let root = map["sourceRoot"] as? String ?? ""
    var results: [ShaarOriginalSource] = []
    for (index, source) in sources.enumerated() {
      guard let content = contents[index] as? String,
        content.utf8.count <= maximumBytes,
        let path = displayPath(sourcePath(source, root: root)),
        let url = originalURL(path: path, resourceURL: resourceURL)
      else { continue }
      let mime = path.hasSuffix(".css") ? "text/css" : "text/javascript"
      results.append(ShaarOriginalSource(url: url, content: content, mimeType: mime))
    }
    return results
  }

  private static func sourcePath(_ source: String, root: String) -> String {
    if root.isEmpty || source.contains("://") { return source }
    if root.hasSuffix("/") || source.hasPrefix("/") { return root + source }
    return root + "/" + source
  }

  private static func displayPath(_ raw: String) -> String? {
    guard raw.count <= 2_048, !raw.contains("\0") else { return nil }
    var path = raw.replacingOccurrences(of: "\\", with: "/")
    for prefix in ["webpack://_N_E/", "webpack://", "vite://", "file://"] {
      if path.hasPrefix(prefix) {
        path.removeFirst(prefix.count)
        break
      }
    }
    let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "/")
  }

  private static func originalURL(path: String, resourceURL: URL) -> String? {
    guard let host = resourceURL.host else { return nil }
    var components = URLComponents()
    components.scheme = "shaar-original"
    components.host = host
    components.path = "/\(path)"
    return components.url?.absoluteString
  }
}
