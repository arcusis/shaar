// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Maps development-server resources to existing files under an explicit workspace root.
enum DevelopmentSourceResolver {
  static func workspaceURL(for page: URL) -> URL? {
    guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      components.host?.isEmpty == false, components.user == nil, components.password == nil,
      (components.port.map { (0...65535).contains($0) } ?? true)
    else { return nil }
    components.path = "/.well-known/appspecific/com.chrome.devtools.json"
    components.query = nil
    components.fragment = nil
    return components.url
  }

  static func workspaceRoot(from data: Data) -> String? {
    guard data.count <= 16_384,
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let workspace = document["workspace"] as? [String: Any],
      let root = workspace["root"] as? String, root.hasPrefix("/"), root.count <= 1024
    else { return nil }
    return root
  }

  static func sourceMapURL(in body: String, resourceURL: URL) -> URL? {
    guard let reference = sourceMapReference(in: body),
      !reference.hasPrefix("data:"),
      let url = URL(string: reference, relativeTo: resourceURL)?.absoluteURL,
      url.user == nil, url.password == nil,
      sameOrigin(url, resourceURL)
    else { return nil }
    return url
  }

  static func sourceMapReference(in body: String) -> String? {
    guard body.utf8.count <= 5 * 1_048_576 else { return nil }
    let pattern = #"(?:\/\/[#@]|\/\*[#@])\s*sourceMappingURL=([^\s*]+)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).last,
      let range = Range(match.range(at: 1), in: body)
    else { return nil }
    return String(body[range])
  }

  static func locations(
    resourceURL: URL, workspaceRoot: String, framework: DevelopmentFramework?,
    sourceMap: Data?
  ) -> [InspectorSourceLocation] {
    let root = URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL
    guard workspaceRoot.hasPrefix("/"), root.path != "/",
      FileManager.default.fileExists(atPath: root.path)
    else { return [] }
    let mapSources = sourceMap.flatMap(sourcePaths) ?? []
    let paths = mapSources.isEmpty ? directPaths(resourceURL, framework: framework) : mapSources
    var seen = Set<String>()
    return paths.prefix(256).compactMap { raw in
      guard let file = candidateURL(raw, under: root) else { return nil }
      var isDirectory: ObjCBool = false
      guard file.path.hasPrefix(root.path + "/"),
        FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        seen.insert(file.path).inserted
      else { return nil }
      return InspectorSourceLocation(path: file.path, line: nil, column: nil)
    }
  }

  static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
    guard let a = URLComponents(url: first, resolvingAgainstBaseURL: false),
      let b = URLComponents(url: second, resolvingAgainstBaseURL: false)
    else { return false }
    return a.scheme?.lowercased() == b.scheme?.lowercased()
      && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
      && ["http", "https"].contains(a.scheme?.lowercased() ?? "")
  }

  private static func sourcePaths(_ data: Data) -> [String]? {
    guard data.count <= 1_048_576,
      let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      map["version"] as? Int == 3, let sources = map["sources"] as? [String],
      sources.count <= 256
    else { return nil }
    let sourceRoot = map["sourceRoot"] as? String ?? ""
    guard sourceRoot.count <= 1024 else { return nil }
    return sources.map { sourceRoot + $0 }
  }

  private static func directPaths(_ url: URL, framework: DevelopmentFramework?) -> [String] {
    guard framework == .vite || framework == .astro || framework == .svelteKit,
      let path = url.path.removingPercentEncoding
    else { return [] }
    return [path]
  }

  private static func candidateURL(_ raw: String, under root: URL) -> URL? {
    if raw.hasPrefix("file://") {
      guard let source = URL(string: raw), source.isFileURL,
        source.query == nil, source.fragment == nil
      else { return nil }
      return source.resolvingSymlinksInPath().standardizedFileURL
    }
    guard let relative = normalizedPath(raw),
      !relative.split(separator: "/").contains("..")
    else { return nil }
    return root.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
  }

  private static func normalizedPath(_ raw: String) -> String? {
    guard raw.count <= 1024, !raw.contains("\0"), !raw.contains("\\") else { return nil }
    var path = raw
    for prefix in ["webpack://_N_E/", "webpack://", "vite://"] {
      if path.hasPrefix(prefix) {
        path.removeFirst(prefix.count)
        break
      }
    }
    while path.hasPrefix("./") { path.removeFirst(2) }
    while path.hasPrefix("/") { path.removeFirst() }
    guard !path.isEmpty, !path.contains("://"), !path.contains("?"), !path.contains("#")
    else { return nil }
    return path.removingPercentEncoding
  }
}

enum DevelopmentSourceHTTP {
  static func load(_ url: URL) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    let session = URLSession(
      configuration: configuration, delegate: NoSourceRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let finalURL = http.url, DevelopmentSourceResolver.sameOrigin(finalURL, url),
      data.count <= 5 * 1_048_576
    else { throw URLError(.badServerResponse) }
    return data
  }
}

private final class NoSourceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
